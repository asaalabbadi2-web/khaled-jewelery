"""Inventory API Blueprint — /api/inventory/

Endpoints:
    GET  /balance                  أرصدة الـ buckets (branch+category+karat)
    GET  /balance/summary          تجميع للـ dashboard
    GET  /count                    قائمة جلسات الجرد
    POST /count                    فتح جلسة جرد جديدة
    GET  /count/<id>               تفاصيل جلسة + سطورها
    PUT  /count/<id>/entry         تسجيل عدّ فعلي لـ bucket
    POST /count/<id>/close         إغلاق الجلسة (تحضير للاعتماد)
    POST /count/<id>/approve       اعتماد الجلسة + توليد قيود التسوية
    POST /count/<id>/cancel        إلغاء جلسة مفتوحة
    POST /adjustment               تسوية يدوية مستقلة
    GET  /adjustment/<id>          تفاصيل تسوية + سطورها
    GET  /adjustment-reasons       قائمة أسباب التسوية المقننة
    GET  /reconciliation           تقرير المطابقة الرباعي
    GET  /health                   تقرير صحة محرك الجرد

Permissions:
    inventory.view    → GET  balance, balance/summary, count, count/<id>,
                              adjustment/<id>, adjustment-reasons, reconciliation*, health*
    inventory.count   → POST count, PUT entry, POST close, POST cancel
    inventory.approve → POST approve, POST adjustment
    (* reconciliation و health: inventory.approve فقط — بيانات تدقيق حساسة)
"""
from __future__ import annotations

from datetime import datetime
from flask import Blueprint, request, jsonify, g

from auth_decorators import require_permission
from models import db, Branch, Category, InventoryBalance, InventoryCountSession, SafeBox

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
    """أرصدة الـ buckets مع فلاتر اختيارية.

    Query params:
        branch_id   (int)   فلتر بالفرع
        category_id (int)   فلتر بالتصنيف
        karat       (float) فلتر بالعيار
    """
    q = InventoryBalance.query

    branch_id = request.args.get('branch_id', type=int)
    category_id = request.args.get('category_id', type=int)
    karat = request.args.get('karat', type=float)

    if branch_id is not None:
        q = q.filter_by(branch_id=branch_id)
    if category_id is not None:
        q = q.filter_by(category_id=category_id)
    if karat is not None:
        q = q.filter_by(karat=karat)

    rows = q.order_by(
        InventoryBalance.branch_id,
        InventoryBalance.category_id,
        InventoryBalance.karat,
    ).all()

    return jsonify([_balance_row(r) for r in rows]), 200


@inventory_bp.route('/balance/summary', methods=['GET'])
@require_permission('inventory.view')
def get_balance_summary():
    """تجميع للـ dashboard: إجمالي ال��رصدة مجمّعة بالفرع وبالعيار.

    Returns:
        by_branch: [{branch_id, branch_name, total_weight}]
        by_karat:  [{karat, total_weight}]
        grand_total_weight: float
    """
    from sqlalchemy import func

    # تجميع بالفرع
    by_branch_q = (
        db.session.query(
            InventoryBalance.branch_id,
            func.sum(InventoryBalance.balance).label('total'),
        )
        .group_by(InventoryBalance.branch_id)
        .all()
    )
    branch_names = {
        b.id: b.name
        for b in Branch.query.filter(
            Branch.id.in_([r.branch_id for r in by_branch_q if r.branch_id])
        ).all()
    }
    by_branch = [
        {
            'branch_id': r.branch_id,
            'branch_name': branch_names.get(r.branch_id, '—'),
            'total_weight': round(float(r.total or 0), 4),
        }
        for r in by_branch_q
    ]

    # تجميع بالعيار
    by_karat_q = (
        db.session.query(
            InventoryBalance.karat,
            func.sum(InventoryBalance.balance).label('total'),
        )
        .group_by(InventoryBalance.karat)
        .order_by(InventoryBalance.karat)
        .all()
    )
    by_karat = [
        {'karat': r.karat, 'total_weight': round(float(r.total or 0), 4)}
        for r in by_karat_q
    ]

    grand_total = sum(r['total_weight'] for r in by_karat)

    return jsonify({
        'by_branch': by_branch,
        'by_karat': by_karat,
        'grand_total_weight': round(grand_total, 4),
        'generated_at': datetime.now().isoformat(),
    }), 200


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


# ── Adjustments ──────────────────────��──────────────────────────────���─────────

@inventory_bp.route('/adjustment', methods=['POST'])
@require_permission('inventory.approve')
def create_manual_adjustment():
    """تسوية يدوية مست��لة (فاقد تصنيع، خسارة، تصحيح).

    Body (JSON):
        branch_id  (int, required)
        reason     (str, required)
        lines      (list, required): [{category_id, karat, variance_weight}]
        auto_post  (bool, default true)
    """
    from services.inventory_adjustment_service import InventoryAdjustmentService

    data = request.get_json(silent=True) or {}
    branch_id = data.get('branch_id')
    reason = data.get('reason', '').strip()
    lines_data = data.get('lines', [])
    auto_post = data.get('auto_post', True)

    if not branch_id:
        return _err('branch_id مطلوب')
    if not reason:
        return _err('reason مطلوب')
    if not lines_data or not isinstance(lines_data, list):
        return _err('lines مطلوبة و��جب أن تكون قائمة')

    # تحقق من كل سطر
    for i, line in enumerate(lines_data):
        if line.get('category_id') is None:
            return _err(f'السطر {i+1}: category_id مطلوب')
        if line.get('karat') is None:
            return _err(f'السطر {i+1}: karat مطلوب')
        if line.get('variance_weight') is None:
            return _err(f'السطر {i+1}: variance_weight مطلوب')

    try:
        adjustment = InventoryAdjustmentService.create_manual(
            branch_id=branch_id,
            lines_data=lines_data,
            reason=reason,
            created_by=_current_user(),
            auto_post=bool(auto_post),
        )
        db.session.commit()
        return jsonify(_adjustment_detail(adjustment)), 201
    except ValueError as e:
        db.session.rollback()
        return _err(str(e))
    except Exception as e:
        db.session.rollback()
        return _err(f'خطأ في إنشاء التسوية: {e}', 500)


@inventory_bp.route('/adjustment/<int:adjustment_id>', methods=['GET'])
@require_permission('inventory.view')
def get_adjustment(adjustment_id: int):
    """تفاصيل تسوية مع سطورها."""
    from models import InventoryAdjustment
    adj = InventoryAdjustment.query.get(adjustment_id)
    if not adj:
        return _err('��لتسوية غير موجودة', 404)
    return jsonify(_adjustment_detail(adj)), 200


# ── Admin / Migration ────────────────────────────────────────────────────────

@inventory_bp.route('/admin/backfill-invoices', methods=['POST'])
@require_permission('inventory.approve')
def backfill_invoices():
    """يُعيد معالجة الفواتير التاريخية وتسجيلها في InventoryLedger + InventoryBalance.

    آمن تماماً: الـ posting service يتجاهل الفواتير المُسجَّلة مسبقاً (idempotent).
    يُستخدم مرة واحدة عند أول إعداد النظام.
    """
    from models import Invoice
    from services.inventory_posting_service import InventoryPostingService

    invoices = Invoice.query.order_by(Invoice.id.asc()).all()
    posted_count = 0
    skipped_count = 0
    errors = []

    for inv in invoices:
        try:
            entries = InventoryPostingService.post(inv)
            if entries:
                posted_count += len(entries)
            else:
                skipped_count += 1
        except Exception as e:
            errors.append({'invoice_id': inv.id, 'error': str(e)})

    try:
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        return _err(f'خطأ في حفظ البيانات: {e}', 500)

    from models import InventoryBalance
    balance_count = InventoryBalance.query.count()

    return jsonify({
        'invoices_processed': len(invoices),
        'ledger_entries_created': posted_count,
        'invoices_skipped': skipped_count,
        'balance_buckets_now': balance_count,
        'errors': errors,
    }), 200


# ── Reports ───────────────────────────────────────────────────────────────────

@inventory_bp.route('/reconciliation', methods=['GET'])
@require_permission('inventory.approve')
def get_reconciliation():
    """تقرير المطابقة الرباعي: Ledger / Balance / Physical Count / GL.

    مخصص للمدير والمحاسب للتدقيق الدوري.
    """
    from services.inventory_reconciliation_report import InventoryReconciliationReport
    snap = InventoryReconciliationReport.build()
    return jsonify(snap.to_dict()), 200


@inventory_bp.route('/health', methods=['GET'])
@require_permission('inventory.approve')
def get_health():
    """تقرير صحة محرك الجرد: مخالفات، جلسات مفتوحة، تسويات معلقة."""
    from services.inventory_health_report import InventoryHealthReport
    report = InventoryHealthReport.build()
    return jsonify(report.to_dict() if hasattr(report, 'to_dict') else report.__dict__), 200


# ── Serialisers ──────────────────────��────────────────────────────────────────

def _balance_row(r) -> dict:
    return {
        'id':                    r.id,
        'branch_id':             r.branch_id,
        'category_id':           r.category_id,
        'karat':                 r.karat,
        'balance':               round(float(r.balance or 0), 4),
        'snapshot_max_ledger_id': r.snapshot_max_ledger_id,
        'updated_at':            r.updated_at.isoformat() if r.updated_at else None,
    }


def _session_summary(s) -> dict:
    return {
        'id':                 s.id,
        'branch_id':          s.branch_id,
        'safe_box_id':        s.safe_box_id,
        'entry_id':           s.entry_id,
        'status':             s.status,
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


def _adjustment_summary(adj) -> dict | None:
    if adj is None:
        return None
    return {
        'id':              adj.id,
        'branch_id':       adj.branch_id,
        'adjustment_type': adj.adjustment_type,
        'status':          adj.status,
        'reason_code':     adj.reason,
        'note':            adj.notes,
        'created_by':      adj.created_by,
        'created_at':      adj.created_at.isoformat() if adj.created_at else None,
        'posted_by':       adj.posted_by,
        'posted_at':       adj.posted_at.isoformat() if adj.posted_at else None,
    }


def _adjustment_detail(adj) -> dict:
    summary = _adjustment_summary(adj)
    summary['lines'] = [
        {
            'id':               ln.id,
            'branch_id':        ln.branch_id,
            'category_id':      ln.category_id,
            'karat':            ln.karat,
            'expected_weight':  round(float(ln.expected_weight or 0), 4),
            'counted_weight':   round(float(ln.counted_weight or 0), 4),
            'variance_weight':  round(float(ln.variance_weight), 4),
            'notes':            ln.notes,
        }
        for ln in adj.lines
    ]
    return summary
