"""Inventory API Blueprint — /api/inventory/ (ADR-045: the stock is the entry lines)

Endpoints:
    GET  /balance                  المخزون لكل (موقع × تصنيف × عيار)
    GET  /balance/summary          الإجمالي بالموقع وبالعيار، ونصيب «بلا تصنيف»
    GET  /count                    قائمة جلسات الجرد
    POST /count                    فتح جلسة جرد لموقع أو لكل المواقع
    GET  /count/<id>               تفاصيل جلسة + سطورها
    PUT  /count/<id>/entry         تسجيل عدّ فعلي لسطر
    POST /count/<id>/close         إغلاق الجلسة (تحضير للاعتماد)
    POST /count/<id>/approve       اعتماد الجلسة + قيد فروق الجرد في الدفاتر
    POST /count/<id>/cancel        إلغاء جلسة مفتوحة
    GET  /adjustment-reasons       أسباب فروق الجرد المقننة
    GET  /reconciliation           الدفاتر والمصنَّف وآخر جرد لكل (موقع × عيار)
    GET  /health                   ما قد يكون خطأً في المخزون

The old inventory ledger's manual adjustment, its view and its backfill are
retired with it (ADR-045 C3): a difference is a count, and a count is an entry.

Permissions:
    inventory.view    → GET  balance, balance/summary, count, count/<id>, adjustment-reasons
    inventory.count   → POST count, PUT entry, POST close, POST cancel
    inventory.approve → POST approve, GET reconciliation, GET health
"""
from __future__ import annotations

from datetime import datetime
from flask import Blueprint, request, jsonify, g

from auth_decorators import require_permission
from models import db, Category, InventoryCountLine, InventoryCountSession, SafeBox

# ── Adjustment reason codes ───────────────────────────────────────────────────
# Source of truth for the coded reason list.  Flutter reads this via
# GET /inventory/adjustment-reasons — do NOT hardcode reasons in the client.
# After 3–5 Pilot cycles, run:
#   SELECT reason, COUNT(*) FROM inventory_adjustment GROUP BY reason ORDER BY 2 DESC
# to see the distribution and decide whether SKU/Barcode investment is justified.
ADJUSTMENT_REASONS: list[dict] = [
    {'code': 'COUNT_ERROR', 'label': 'خطأ عدّ',       'requires_note': False},
    {'code': 'LOSS',        'label': 'فاقد',           'requires_note': True},
    {'code': 'NEW_ITEM',    'label': 'قطعة جديدة',     'requires_note': False},
    {'code': 'OTHER',       'label': 'سبب آخر',        'requires_note': True},
]
_VALID_REASON_CODES = {r['code'] for r in ADJUSTMENT_REASONS}
_REASON_REQUIRES_NOTE = {r['code']: r['requires_note'] for r in ADJUSTMENT_REASONS}

# Category name cache — populated lazily, cleared on first request after restart
_category_name_cache: dict[int, str] = {}

def _category_name(category_id) -> str | None:
    if category_id is None:
        return None
    if category_id not in _category_name_cache:
        cat = Category.query.get(category_id)
        _category_name_cache[category_id] = cat.name if cat else f'#{category_id}'
    return _category_name_cache[category_id]

inventory_bp = Blueprint('inventory', __name__, url_prefix='/api/inventory')


# ── helpers ───────────────��──────────────────────────────��────────────────────

def _current_user() -> str:
    u = getattr(g, 'current_user', None)
    if u is None:
        return 'unknown'
    return getattr(u, 'username', None) or getattr(u, 'email', None) or str(u.id)


def _get_session_or_404(session_id: int):
    s = InventoryCountSession.query.get(session_id)
    if s is None:
        return None, jsonify({'error': 'جلسة الجرد غير موجودة', 'session_id': session_id}), 404
    return s, None, None


def _resolve_reason(raw: str) -> str | None:
    """Return the canonical code for a reason; None if unrecognised."""
    if not raw:
        return None
    if raw in _VALID_REASON_CODES:
        return raw
    # Accept legacy labels for backward compat
    match = next((r['code'] for r in ADJUSTMENT_REASONS if r['label'] == raw), None)
    return match


def _err(msg: str, code: int = 400):
    return jsonify({'error': msg}), code


# ── Balance ───────────────���─────────────────────────────��─────────────────────

@inventory_bp.route('/balance', methods=['GET'])
@require_permission('inventory.view')
def get_balance():
    """The stock per (location, category, karat) -- the one reader (ADR-045 C2).

    Query params: safe_box_id, category_id, karat. The old inventory ledger's
    buckets by branch are retired (C3).
    """
    from services.stock_ledger import balance_rows
    return jsonify(balance_rows(safe_box_id=request.args.get('safe_box_id', type=int),
                                category_id=request.args.get('category_id', type=int),
                                karat=request.args.get('karat', type=float))), 200


@inventory_bp.route('/balance/summary', methods=['GET'])
@require_permission('inventory.view')
def get_balance_summary():
    """Totals by location (main karat), by karat (grams), the grand total and
    the unclassified share (ADR-045 C2)."""
    from services.stock_ledger import balance_summary
    return jsonify(balance_summary(now=datetime.now())), 200


# ── Count Sessions ────────────────────────���──────────────────────────���────────

@inventory_bp.route('/count', methods=['GET'])
@require_permission('inventory.view')
def list_count_sessions():
    """قائمة جلسات الج��د مع فلاتر.

    Query params:
        branch_id (int)
        status    (str): open | counting | closed | approved
        limit     (int): default 50
    """
    q = InventoryCountSession.query

    branch_id = request.args.get('branch_id', type=int)
    status = request.args.get('status')
    limit = min(request.args.get('limit', 50, type=int), 200)

    if branch_id is not None:
        q = q.filter_by(branch_id=branch_id)
    if status:
        q = q.filter_by(status=status)

    sessions = q.order_by(InventoryCountSession.id.desc()).limit(limit).all()
    return jsonify([_session_summary(s) for s in sessions]), 200


@inventory_bp.route('/count', methods=['POST'])
@require_permission('inventory.count')
def open_count_session():
    """فتح جلسة جرد جديدة وتعبئة السطور من الأرصدة الحالية.

    Body (JSON):
        safe_box_id (int, optional) -- one stock location; omitted: every one (ADR-045 C1)
        branch_id   (int, optional)
        notes       (str, optional)
    """
    from services.inventory_count_service import InventoryCountService

    data = request.get_json(silent=True) or {}
    branch_id = data.get('branch_id')
    safe_box_id = data.get('safe_box_id')

    # blind_count=True by default — manager may pass false for spot-checks
    blind_count = data.get('blind_count', True)
    if not isinstance(blind_count, bool):
        blind_count = str(blind_count).lower() not in ('false', '0', 'no')

    session_type = data.get('session_type', 'periodic')

    try:
        session = InventoryCountService.open_session(
            branch_id=branch_id,
            opened_by=_current_user(),
            now=datetime.now(),
            notes=data.get('notes', ''),
            blind_count=blind_count,
            session_type=session_type,
            safe_box_id=int(safe_box_id) if safe_box_id else None,
        )
        db.session.flush()
        if session_type == 'opening':
            InventoryCountService.populate_opening_lines(session)
        else:
            InventoryCountService.populate_lines(session)
        db.session.commit()
        return jsonify(_session_detail(session)), 201
    except ValueError as e:
        db.session.rollback()
        return _err(str(e))
    except Exception as e:
        db.session.rollback()
        return _err(f'خطأ في فتح الجلسة: {e}', 500)


@inventory_bp.route('/count/<int:session_id>', methods=['GET'])
@require_permission('inventory.view')
def get_count_session(session_id: int):
    """تفاصيل جلسة الجرد مع كامل سطورها."""
    s, err, code = _get_session_or_404(session_id)
    if err:
        return err, code
    return jsonify(_session_detail(s)), 200


@inventory_bp.route('/count/<int:session_id>/entry', methods=['PUT'])
@require_permission('inventory.count')
def record_count_entry(session_id: int):
    """تسجيل (أو تحديث) العدّ الفعلي لـ bucket واحد.

    Body (JSON):
        category_id    (int,   required; null -- «بلا تصنيف»)
        karat          (float, required)
        counted_weight (float, required)
        safe_box_id    (int,   required when the session counts every location)
    """
    from services.inventory_count_service import InventoryCountService

    s, err, code = _get_session_or_404(session_id)
    if err:
        return err, code

    data = request.get_json(silent=True) or {}
    category_id = data.get('category_id')
    karat = data.get('karat')
    counted_weight = data.get('counted_weight')

    if 'category_id' not in data or karat is None or counted_weight is None:
        return _err('category_id و karat و counted_weight مطلوبة')

    try:
        line = InventoryCountService.record_count(
            session=s,
            category_id=category_id,
            karat=float(karat),
            counted_weight=float(counted_weight),
            counted_by=_current_user(),
            now=datetime.now(),
            safe_box_id=data.get('safe_box_id'),
        )
        is_opening = getattr(s, 'session_type', 'periodic') == 'opening'
        db.session.commit()
        return jsonify(_count_line(line, reveal_expected=_should_reveal_expected(s), is_opening=is_opening)), 200
    except ValueError as e:
        db.session.rollback()
        return _err(str(e))
    except Exception as e:
        db.session.rollback()
        return _err(f'خطأ في تسجيل العدّ: {e}', 500)


@inventory_bp.route('/count/<int:session_id>/close', methods=['POST'])
@require_permission('inventory.count')
def close_count_session(session_id: int):
    """إغلاق الجلسة.

    Body (JSON):
        force (bool, default false) — إغلاق حتى مع وجود أصناف لم تُعدّ.
            يُستخدم عندما تكون بعض القطع خارج المحل (عند الصائغ، مرهونة…).
            الأصناف غير المعدودة تظهر في تقرير المطابقة كـ "غير محدد".
    """
    from services.inventory_count_service import InventoryCountService

    s, err, code = _get_session_or_404(session_id)
    if err:
        return err, code

    data = request.get_json(silent=True) or {}
    force = bool(data.get('force', False))
    zero_uncounted = bool(data.get('zero_uncounted', False))

    try:
        uncounted = InventoryCountService.close_session(
            s, force=force, zero_uncounted=zero_uncounted, now=datetime.now()
        )
        db.session.commit()
        resp = _session_summary(s)
        if uncounted:
            resp['warning'] = f'{uncounted} صنف لم يُعدّ — تم الإغلاق بالقوة'
        return jsonify(resp), 200
    except ValueError as e:
        db.session.rollback()
        return _err(str(e))
    except Exception as e:
        db.session.rollback()
        return _err(f'خطأ في إغلاق الجلسة: {e}', 500)


@inventory_bp.route('/count/<int:session_id>/cancel', methods=['POST'])
@require_permission('inventory.count')
def cancel_count_session(session_id: int):
    """إلغاء جلسة فُتحت بالخطأ (فرع خاطئ، تهيئة خاطئة).

    فقط الجلسات بحالة open أو counting يمكن إلغاؤها.
    الجلسات المغلقة أو المعتمدة لا يمكن إلغاؤها.
    """
    s, err, code = _get_session_or_404(session_id)
    if err:
        return err, code

    if s.status not in ('open', 'counting'):
        return _err(f'لا يمكن إلغاء جلسة بحالة "{s.status}" — فقط الجلسات المفتوحة قابلة للإلغاء')

    s.status = 'cancelled'
    s.closed_at = datetime.now()
    try:
        db.session.commit()
        return jsonify(_session_summary(s)), 200
    except Exception as e:
        db.session.rollback()
        return _err(f'خطأ في إلغاء الجلسة: {e}', 500)


@inventory_bp.route('/adjustment-reasons', methods=['GET'])
@require_permission('inventory.view')
def get_adjustment_reasons():
    """قائمة أسباب التسوية المقننة — مصدر الحقيقة للـ Flutter dropdown."""
    return jsonify(ADJUSTMENT_REASONS), 200


@inventory_bp.route('/count/<int:session_id>/approve', methods=['POST'])
@require_permission('inventory.approve')
def approve_count_session(session_id: int):
    """اعتماد الجلسة — يكتب قيد فروق الجرد في الدفاتر (ADR-045 C1).

    Body (JSON):
        reason (str, required for periodic sessions with variance)
               يجب أن يكون code أو label من ADJUSTMENT_REASONS.
               مثال: "counting_error" أو "خطأ عدّ"
    """
    from services.inventory_count_service import InventoryCountService

    # SELECT FOR UPDATE prevents two concurrent approval requests from both
    # reading status='closed' and creating duplicate adjustment entries.
    s = InventoryCountSession.query.with_for_update().get(session_id)
    if s is None:
        return _err('جلسة الجرد غير موجودة', 404)

    data = request.get_json(silent=True) or {}
    raw_code = (data.get('reason_code') or data.get('reason') or '').strip()
    note     = (data.get('note') or '').strip()

    reason_code = _resolve_reason(raw_code)
    is_periodic = getattr(s, 'session_type', 'periodic') == 'periodic'

    if is_periodic and reason_code is None:
        valid = '، '.join(f'{r["label"]} ({r["code"]})' for r in ADJUSTMENT_REASONS)
        return _err(f'reason_code مطلوب ومقبول: {valid}')

    if reason_code and _REASON_REQUIRES_NOTE.get(reason_code) and not note:
        return _err(f'سبب "{reason_code}" يتطلب ملاحظة توضيحية (note)')

    if reason_code is None:
        reason_code = 'OTHER'

    try:
        session, entry = InventoryCountService.approve_session(
            session=s,
            approved_by=_current_user(),
            now=datetime.now(),
            adjustment_reason=reason_code,
            adjustment_note=note,
        )
        db.session.commit()
        # The differences are an entry in the books now (ADR-045 C1), not an
        # adjustment of the retired inventory ledger.
        return jsonify({
            'session': _session_summary(session),
            'entry': ({'id': entry.id, 'entry_number': entry.entry_number} if entry else None),
            'adjustment': None,
        }), 200
    except ValueError as e:
        db.session.rollback()
        return _err(str(e))
    except Exception as e:
        db.session.rollback()
        return _err(f'خطأ في اعتماد الجلسة: {e}', 500)


# ── Reports ───────────────────────────────────────────────────────────────────

@inventory_bp.route('/reconciliation', methods=['GET'])
@require_permission('inventory.approve')
def get_reconciliation():
    """Per (location, karat): the books, how much is classified, the last
    approved count (ADR-045 C2). The stock IS the books (A1): the old four-way
    matching (ledger / balance / count / GL) is retired."""
    from services.stock_ledger import stock_audit
    return jsonify(stock_audit(now=datetime.now())), 200


@inventory_bp.route('/health', methods=['GET'])
@require_permission('inventory.approve')
def get_health():
    """What can still be wrong with the stock: allocations against their lines,
    open count sessions, the last approved count, the unclassified share."""
    from services.stock_ledger import stock_audit
    audit = stock_audit(now=datetime.now())
    return jsonify({k: audit[k] for k in ('has_issues', 'metrics', 'generated_at')}), 200


# ── Serialisers ──────────────────────��────────────────────────────────────────

def _session_summary(s) -> dict:
    return {
        'id':                 s.id,
        'branch_id':          s.branch_id,
        'safe_box_id':        s.safe_box_id,
        'safe_box_name':      _safe_box_name(s.safe_box_id),
        'entry_id':           s.entry_id,
        'status':             s.status,
        'lines_total':        InventoryCountLine.query.filter_by(session_id=s.id).count(),
        'lines_counted':      InventoryCountLine.query.filter_by(session_id=s.id)
                              .filter(InventoryCountLine.counted_weight.isnot(None)).count(),
        'session_type':       getattr(s, 'session_type', 'periodic') or 'periodic',
        'blind_count':        getattr(s, 'blind_count', True),
        'snapshot_ledger_id': s.snapshot_ledger_id,
        'opened_by':          s.opened_by,
        'opened_at':          s.opened_at.isoformat() if s.opened_at else None,
        'closed_at':          s.closed_at.isoformat() if s.closed_at else None,
        'approved_by':        s.approved_by,
        'approved_at':        s.approved_at.isoformat() if s.approved_at else None,
        'notes':              s.notes,
    }


def _session_detail(s) -> dict:
    summary = _session_summary(s)
    reveal = _should_reveal_expected(s)
    is_opening = getattr(s, 'session_type', 'periodic') == 'opening'
    summary['lines'] = [_count_line(ln, reveal_expected=reveal, is_opening=is_opening) for ln in s.lines]
    return summary


def _safe_box_name(safe_box_id):
    if not safe_box_id:
        return None
    box = db.session.get(SafeBox, int(safe_box_id))
    return box.name if box else None


def _count_line(ln, reveal_expected: bool = False, is_opening: bool = False) -> dict:
    """Serialise a count line.

    Defaults to reveal_expected=False (fail-secure).
    Callers must explicitly pass reveal_expected=True or use _should_reveal_expected().
    When False: expected_weight, expected_ledger_id, and variance are omitted from
    the response, preventing any client from reading the expected value during a
    blind-count session — regardless of UI logic.
    """
    return {
        'id':               ln.id,
        'session_id':       ln.session_id,
        'branch_id':        ln.branch_id,
        'safe_box_id':      ln.safe_box_id,
        'safe_box_name':    _safe_box_name(ln.safe_box_id),
        'category_id':      ln.category_id,
        'category_name':    _category_name(ln.category_id),
        'karat':            ln.karat,
        'expected_weight':  None if is_opening else (round(float(ln.expected_weight or 0), 4) if reveal_expected else None),
        'expected_ledger_id': None if is_opening else (ln.expected_ledger_id if reveal_expected else None),
        'counted_weight':   round(float(ln.counted_weight), 4) if ln.counted_weight is not None else None,
        'variance':         None if is_opening else (round(float(ln.variance), 4) if ln.variance is not None and reveal_expected else None),
        'counted_by':       ln.counted_by,
        'counted_at':       ln.counted_at.isoformat() if ln.counted_at else None,
        'notes':            ln.notes,
    }


def _should_reveal_expected(session) -> bool:
    """True when expected_weight may be shown to the client.

    Rules:
      - Non-blind sessions: always reveal
      - Blind sessions: reveal only after session is closed or approved
    """
    blind = getattr(session, 'blind_count', True)
    if not blind:
        return True
    return session.status in ('closed', 'approved')

