"""Safe-boxes domain routes — safe_boxes_bp registered under /api in app.py."""
from __future__ import annotations

import traceback
from datetime import datetime, timedelta

from flask import Blueprint, g, jsonify, request
from sqlalchemy import func, or_

from models import (
    db,
    Account,
    Employee,
    Invoice,
    JournalEntry,
    PaymentMethod,
    SafeBox,
    SafeBoxTransaction,
    Voucher,
    VoucherAccountLine,
)

from auth_decorators import require_permission

from services.live_balances import (
    live_balances_by_account_ids,
    safe_box_balance,
    safe_box_balances_bulk,
)

from pricing.karat_service import convert_to_main_karat, get_main_karat
from accounting.voucher_engine import (
    generate_voucher_number,
    post_entry_of_approved_voucher,
    _append_safe_transactions_for_voucher,
)
from accounting.safe_boxes import _ensure_safe_box_transactions_for_invoice_je
from services.safebox_subledger import (
    DEFAULT_IGNORED_REF_TYPES,
    DRIFT_THRESHOLD,
    subledger_keyed_breakdown,
    subledger_totals_by_box,
)

safe_boxes_bp = Blueprint('safe_boxes', __name__)

@safe_boxes_bp.route('/safe-boxes/<int:safe_box_id>/transactions', methods=['GET'])
@require_permission('safe_boxes.view')
def list_safe_box_transactions(safe_box_id: int):
    """List safe box transactions (ledger) with optional date range.

    Query params:
      - from (ISO datetime)
      - to (ISO datetime)
      - limit (default 200)
    """
    SafeBox.query.get_or_404(safe_box_id)

    q = SafeBoxTransaction.query.filter_by(safe_box_id=safe_box_id)
    from_value = request.args.get('from')
    to_value = request.args.get('to')
    try:
        if from_value:
            q = q.filter(SafeBoxTransaction.created_at >= datetime.fromisoformat(from_value))
    except Exception:
        return jsonify({'error': 'invalid_from_date'}), 400
    try:
        if to_value:
            q = q.filter(SafeBoxTransaction.created_at <= datetime.fromisoformat(to_value))
    except Exception:
        return jsonify({'error': 'invalid_to_date'}), 400

    try:
        limit = int(request.args.get('limit', 200))
    except Exception:
        limit = 200
    limit = max(1, min(limit, 1000))

    rows = q.order_by(SafeBoxTransaction.created_at.desc()).limit(limit).all()
    return jsonify([r.to_dict() for r in rows])

@safe_boxes_bp.route('/safe-boxes/<int:safe_box_id>/balance', methods=['GET'])
@require_permission('safe_boxes.view')
def get_safe_box_balance(safe_box_id: int):
    """الرصيد الرسمي لخزينة واحدة -- غلاف رفيع حول safe_box_balance (دفتر
    الأستاذ مباشرة). كان هذا الـ endpoint يحسب من SafeBoxTransaction بالكامل
    رغم أن اسمه ووثائقه يَعِدان بـ"ledger" -- وهذا تناقض بين العقد والتنفيذ
    اكتُشف أثناء تتبع انحرافات أرصدة الخزائن عن كشوف حساباتها. لا تُعدّل هذا
    ليعتمد على SafeBoxTransaction مجدداً -- استخدم /safe-boxes/reconciliation
    لو احتجت القيمة المشتقة منه للتشخيص.
    """
    safe_box = SafeBox.query.get_or_404(safe_box_id)
    main_karat = float(get_main_karat() or 21)
    balance = safe_box_balance(safe_box, main_karat=main_karat)

    return jsonify({
        'safe_box_id': safe_box.id,
        'safe_box_name': safe_box.name,
        'cash_balance': balance['cash'],
        'weight_balance': {k: v for k, v in balance['weight'].items() if k != 'total'},
        'total_weight_main_karat': balance['weight']['total'],
        'main_karat': main_karat,
    })

@safe_boxes_bp.route('/safe-boxes/balances', methods=['GET'])
@require_permission('safe_boxes.view')
def list_safe_box_balances():
    """List safe boxes with their official balance (from the general ledger
    via safe_box_balances_bulk -- never SafeBoxTransaction). This is the
    single source of truth for "current balance"; any screen needing the
    SafeBoxTransaction-derived view for diagnostics should call
    /safe-boxes/reconciliation instead.

    Query params:
      - type or safe_type: filter by safe type (cash/bank/gold/check)
      - is_active: true/false

    Returns: list of SafeBox dicts with a `balance` field.
    """

    safe_type = (request.args.get('type') or request.args.get('safe_type') or '').strip()
    is_active_param = (request.args.get('is_active') or '').strip().lower()

    q_safes = SafeBox.query
    if safe_type:
        q_safes = q_safes.filter(SafeBox.safe_type == safe_type)
    if is_active_param in ('true', 'false'):
        q_safes = q_safes.filter(SafeBox.is_active == (is_active_param == 'true'))

    safes = q_safes.order_by(SafeBox.safe_type.asc(), SafeBox.is_default.desc(), SafeBox.name.asc()).all()

    main_karat = float(get_main_karat() or 21)
    balances_by_safe_id = safe_box_balances_bulk(safes, main_karat=main_karat)

    results = []
    for sb in safes:
        sb_dict = sb.to_dict(include_account=True, include_balance=False)

        bal = balances_by_safe_id.get(sb.id) or {'cash': 0.0, 'weight': {}}
        balance = {'cash': bal['cash']}
        account = getattr(sb, 'account', None)
        if bool(getattr(account, 'tracks_weight', False)):
            balance['weight'] = bal['weight']
        sb_dict['balance'] = balance
        results.append(sb_dict)

    return jsonify({
        'rows': results,
        'filters': {
            'safe_type': safe_type or None,
            'is_active': (is_active_param if is_active_param in ('true', 'false') else None),
        },
        'count': len(results),
    })

@safe_boxes_bp.route('/safe-boxes/stones-balance', methods=['GET'])
@require_permission('safe_boxes.view')
def safe_boxes_stones_balance():
    """رصيد الفصوص لكل خزينة ذهب مع تفصيل العيار.

    المنطق:
    1. لكل SBT بوزن فصوص > 0، إذا كانت حقول العيار المخصصة (stones_18k..24k) مُعبّأة → استخدمها.
    2. إذا لم تكن مُعبّأة (بيانات قديمة) → استنتج العيار من حقول الذهب (weight_18k..24k) في نفس الـ SBT.
    """
    safe_box_id_filter = request.args.get('safe_box_id', type=int)

    try:
        q = db.session.query(SafeBoxTransaction).filter(
            SafeBoxTransaction.stones_weight > 0
        )
        if safe_box_id_filter:
            q = q.filter(SafeBoxTransaction.safe_box_id == safe_box_id_filter)
        sbts = q.all()
    except Exception:
        return jsonify({'safes': []})

    # تجميع البيانات لكل خزينة
    safe_totals = {}   # safe_box_id -> {'total': float, '18': float, ...}

    for sbt in sbts:
        sid = sbt.safe_box_id
        if sid not in safe_totals:
            safe_totals[sid] = {'total': 0.0, '18': 0.0, '21': 0.0, '22': 0.0, '24': 0.0}

        sw = float(sbt.stones_weight or 0.0)
        sign = 1.0 if sbt.direction == 'in' else -1.0
        safe_totals[sid]['total'] += sign * sw

        # هل البيانات المفصّلة بالعيار موجودة؟
        s18 = float(getattr(sbt, 'stones_18k', 0.0) or 0.0)
        s21 = float(getattr(sbt, 'stones_21k', 0.0) or 0.0)
        s22 = float(getattr(sbt, 'stones_22k', 0.0) or 0.0)
        s24 = float(getattr(sbt, 'stones_24k', 0.0) or 0.0)
        karat_sum = s18 + s21 + s22 + s24

        if karat_sum > 0.0001:
            # بيانات مفصّلة موجودة → استخدمها مباشرة
            safe_totals[sid]['18'] += sign * s18
            safe_totals[sid]['21'] += sign * s21
            safe_totals[sid]['22'] += sign * s22
            safe_totals[sid]['24'] += sign * s24
        elif sw > 0.0001:
            # بيانات قديمة → استنتج العيار من أوزان الذهب في نفس الـ SBT
            w18 = float(getattr(sbt, 'weight_18k', 0.0) or 0.0)
            w21 = float(getattr(sbt, 'weight_21k', 0.0) or 0.0)
            w22 = float(getattr(sbt, 'weight_22k', 0.0) or 0.0)
            w24 = float(getattr(sbt, 'weight_24k', 0.0) or 0.0)
            gold_total = w18 + w21 + w22 + w24

            if gold_total > 0.0001:
                # توزيع الفصوص بنسبة الذهب في كل عيار
                safe_totals[sid]['18'] += sign * sw * (w18 / gold_total)
                safe_totals[sid]['21'] += sign * sw * (w21 / gold_total)
                safe_totals[sid]['22'] += sign * sw * (w22 / gold_total)
                safe_totals[sid]['24'] += sign * sw * (w24 / gold_total)
            else:
                # لا يوجد معلومات عيار → يُضاف للإجمالي فقط بدون تفصيل
                pass

    # بناء الاستجابة
    all_safe_ids = list(safe_totals.keys())
    safes_map = {}
    if all_safe_ids:
        try:
            safes_map = {s.id: s for s in SafeBox.query.filter(SafeBox.id.in_(all_safe_ids)).all()}
        except Exception:
            pass

    results = []
    for sid, data in safe_totals.items():
        total = round(data['total'], 6)
        if total <= 0.0001:
            continue
        results.append({
            'safe_box_id':    sid,
            'safe_box_name':  safes_map[sid].name if sid in safes_map else str(sid),
            'stones_balance': total,
            'by_karat': {
                '18': round(max(0.0, data['18']), 6),
                '21': round(max(0.0, data['21']), 6),
                '22': round(max(0.0, data['22']), 6),
                '24': round(max(0.0, data['24']), 6),
            },
        })

    return jsonify({'safes': results})

@safe_boxes_bp.route('/safe-boxes/reconciliation', methods=['GET'])
@require_permission('safe_boxes.view')
def safe_boxes_reconciliation():
    """Compare SafeBoxTransaction (sub-ledger) vs posted GL for SafeBox-linked accounts.

    Query params:
      - safe_type: optional safe box type filter (cash/bank/gold/check)
      - is_active: optional true/false
      - safe_box_id: optional; when provided and include_keyed=true, includes keyed breakdown
      - include_keyed: true/false (default false)
      - ignore_ref_types: comma-separated list of SafeBoxTransaction.ref_type values to ignore
      - threshold: numeric diff threshold (default DRIFT_THRESHOLD, 0.01)
    """

    safe_type = (request.args.get('safe_type') or request.args.get('type') or '').strip().lower()
    is_active_param = (request.args.get('is_active') or '').strip().lower()
    include_keyed = (request.args.get('include_keyed') or '').strip().lower() in ('1', 'true', 'yes')

    try:
        safe_box_id = int(request.args.get('safe_box_id')) if request.args.get('safe_box_id') else None
    except Exception:
        return jsonify({'error': 'invalid_safe_box_id'}), 400

    try:
        threshold = float(request.args.get('threshold', DRIFT_THRESHOLD))
    except Exception:
        threshold = DRIFT_THRESHOLD
    threshold = max(0.0, threshold)

    raw_ignore = (request.args.get('ignore_ref_types') or ','.join(DEFAULT_IGNORED_REF_TYPES)).strip()
    ignore_ref_types = [x.strip().lower() for x in raw_ignore.replace(';', ',').split(',') if x.strip()]

    q_safes = SafeBox.query
    if safe_type:
        q_safes = q_safes.filter(SafeBox.safe_type == safe_type)
    if is_active_param in ('true', 'false'):
        q_safes = q_safes.filter(SafeBox.is_active == (is_active_param == 'true'))
    if safe_box_id is not None:
        q_safes = q_safes.filter(SafeBox.id == safe_box_id)

    safes = q_safes.with_entities(SafeBox.id, SafeBox.name, SafeBox.safe_type).all()
    safe_ids = [int(s[0]) for s in safes]
    safe_meta = {int(s[0]): {'safe_box_name': s[1], 'safe_box_type': s[2]} for s in safes}

    if not safe_ids:
        return jsonify({
            'generated_at': datetime.now().isoformat() + 'Z',
            'safe_type': safe_type or None,
            'ignore_ref_types': ignore_ref_types,
            'threshold': threshold,
            'mismatch_count': 0,
            'summary': [],
            'keyed': [],
        })

    # The computation lives in services/safebox_subledger.py, shared with the
    # nightly books invariants, so this screen and that check cannot disagree
    # about what drift is. Moved verbatim; output compared byte-for-byte on a
    # production snapshot before and after.
    totals = subledger_totals_by_box(safe_ids, ignore_ref_types)

    summary = []
    for sid in safe_ids:
        sb_total = float(totals[sid]['sb_total'])
        gl_total = float(totals[sid]['gl_total'])
        diff = sb_total - gl_total
        meta = safe_meta.get(sid, {})
        summary.append({
            'safe_box_id': sid,
            'safe_box_name': meta.get('safe_box_name'),
            'safe_box_type': meta.get('safe_box_type'),
            'sb_total': round(sb_total, 2),
            'gl_total': round(gl_total, 2),
            'diff': round(diff, 2),
            'abs_diff': round(abs(diff), 2),
        })

    summary.sort(key=lambda r: r.get('abs_diff', 0.0), reverse=True)
    mismatches = [r for r in summary if abs(float(r.get('diff') or 0.0)) > threshold]

    keyed = []
    if include_keyed and safe_box_id is not None:
        keyed = subledger_keyed_breakdown(safe_box_id, ignore_ref_types, threshold)

    return jsonify({
        'generated_at': datetime.now().isoformat() + 'Z',
        'safe_type': safe_type or None,
        'ignore_ref_types': ignore_ref_types,
        'threshold': threshold,
        'mismatch_count': len(mismatches),
        'summary': summary,
        'keyed': keyed,
    })

@safe_boxes_bp.route('/safe-boxes/stones-balance', methods=['GET'])
@require_permission('safe_boxes.view')
def get_safe_boxes_stones_balance():
    """رصيد الفصوص لكل خزينة ذهب — مستقل عن العيار.

    stones_balance = SUM(stones_weight, direction='in')
                   - SUM(stones_weight, direction='out')

    Query params:
      - safe_box_id: int (اختياري — لخزينة محددة)
    """
    safe_box_id_param = request.args.get('safe_box_id')

    q_safes = SafeBox.query.filter_by(safe_type='gold', is_active=True)
    if safe_box_id_param:
        try:
            q_safes = q_safes.filter_by(id=int(safe_box_id_param))
        except (TypeError, ValueError):
            pass
    safes = q_safes.order_by(SafeBox.id).all()

    results = []
    for sb in safes:
        col = SafeBoxTransaction.stones_weight
        stones_in = float(
            db.session.query(func.coalesce(func.sum(col), 0.0))
            .filter(SafeBoxTransaction.safe_box_id == sb.id,
                    SafeBoxTransaction.direction == 'in')
            .scalar() or 0.0
        )
        stones_out = float(
            db.session.query(func.coalesce(func.sum(col), 0.0))
            .filter(SafeBoxTransaction.safe_box_id == sb.id,
                    SafeBoxTransaction.direction == 'out')
            .scalar() or 0.0
        )
        results.append({
            'safe_box_id':        sb.id,
            'safe_box_name':      sb.name,
            'stones_in':          round(stones_in, 3),
            'stones_out':         round(stones_out, 3),
            'stones_balance':     round(stones_in - stones_out, 3),
        })

    return jsonify({'safes': results})

@safe_boxes_bp.route('/safe-boxes/purge-duplicate-gold-movement-sbts', methods=['POST'])
@require_permission('admin')
def purge_duplicate_gold_movement_sbts():
    """Delete orphan invoice_sale_gold_movement SBTs that belong to scrap invoices.

    For scrap sale invoices the correct SBT is invoice_scrap_sale.
    Before the guard (inv_gold_type != 'scrap') was in place both SBTs were
    created, doubling the weight-out and causing a GL reconciliation gap.

    Query params:
      - dry_run: true/false (default true)
    """
    dry_run = (request.args.get('dry_run') or 'true').strip().lower() in ('1', 'true', 'yes')

    try:
        rows = (
            db.session.query(SafeBoxTransaction)
            .join(Invoice, Invoice.id == SafeBoxTransaction.invoice_id)
            .filter(
                SafeBoxTransaction.ref_type == 'invoice_sale_gold_movement',
                func.lower(func.coalesce(Invoice.gold_type, 'new')) == 'scrap',
            )
            .all()
        )

        result = []
        for sbt in rows:
            result.append({
                'sbt_id': sbt.id,
                'invoice_id': sbt.invoice_id,
                'safe_box_id': sbt.safe_box_id,
                'direction': sbt.direction,
                'weight_21k': float(sbt.weight_21k or 0),
                'weight_18k': float(sbt.weight_18k or 0),
                'created_at': str(sbt.created_at),
                'action': 'would_delete' if dry_run else 'deleted',
            })
            if not dry_run:
                db.session.delete(sbt)

        if not dry_run:
            db.session.commit()

        return jsonify({
            'dry_run': dry_run,
            'count': len(result),
            'records': result,
        })
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': str(exc)}), 500

@safe_boxes_bp.route('/safe-boxes/repair-transactions', methods=['POST'])
@require_permission('admin')
def repair_safe_box_transactions():
    """Backfill missing SafeBoxTransactions for historical posted invoices.

    Scans all posted invoice JEs whose lines hit safe-box accounts and creates
    missing SBTs.  Idempotent — running it twice produces no duplicates.

    Query params:
      - dry_run: true/false (default true). When true, returns what WOULD be created.
    """
    dry_run = (request.args.get('dry_run') or request.args.get('dryRun') or 'true').strip().lower() in ('1', 'true', 'yes')
    data = request.get_json(silent=True) or {}
    approved_by = (
        (getattr(getattr(g, 'current_user', None), 'username', None))
        or data.get('approved_by')
        or 'system'
    )

    try:
        now = datetime.now()

        # ── Phase A: Post unposted voucher JEs for posted invoices ──
        posted_invoices = Invoice.query.filter(
            func.coalesce(Invoice.is_posted, False) == True,  # noqa: E712
        ).with_entities(Invoice.id).all()
        posted_invoice_ids = [int(r[0]) for r in posted_invoices]

        voucher_je_repairs = []
        if posted_invoice_ids:
            # Find vouchers linked to posted invoices
            linked_vouchers = Voucher.query.filter(
                Voucher.reference_type == 'invoice',
                Voucher.reference_id.in_(posted_invoice_ids),
            ).all()
            voucher_ids = [v.id for v in linked_vouchers]
            voucher_to_invoice = {v.id: v.reference_id for v in linked_vouchers}

            if voucher_ids:
                unposted_voucher_jes = JournalEntry.query.filter(
                    JournalEntry.reference_type == 'voucher',
                    JournalEntry.reference_id.in_(voucher_ids),
                    func.coalesce(JournalEntry.is_deleted, False) == False,  # noqa: E712
                    or_(
                        JournalEntry.is_posted == False,  # noqa: E712
                        JournalEntry.is_posted == None,   # noqa: E711
                    ),
                ).all()

                for vje in unposted_voucher_jes:
                    inv_id = voucher_to_invoice.get(vje.reference_id)
                    if dry_run:
                        voucher_je_repairs.append({
                            'voucher_id': vje.reference_id,
                            'journal_entry_id': vje.id,
                            'invoice_id': inv_id,
                            'action': 'would_post_voucher_je',
                        })
                    else:
                        vje.is_posted = True
                        vje.is_draft = False
                        if not getattr(vje, 'posted_at', None):
                            vje.posted_at = now
                        if not getattr(vje, 'posted_by', None):
                            vje.posted_by = approved_by
                        voucher_je_repairs.append({
                            'voucher_id': vje.reference_id,
                            'journal_entry_id': vje.id,
                            'invoice_id': inv_id,
                            'action': 'posted_voucher_je',
                        })

        # ── Phase B: Create missing SBTs for invoice JE lines on safe-box accounts ──
        # Find all posted invoice JEs
        invoice_jes = (
            JournalEntry.query
            .filter(JournalEntry.reference_type == 'invoice')
            .filter(func.coalesce(JournalEntry.is_posted, True) == True)   # noqa: E712
            .filter(func.coalesce(JournalEntry.is_deleted, False) == False) # noqa: E712
            .filter(func.coalesce(JournalEntry.is_draft, False) == False)   # noqa: E712
            .all()
        )

        # Map safe-box accounts
        all_safe_boxes = SafeBox.query.all()
        sb_account_ids = {int(sb.account_id) for sb in all_safe_boxes if sb.account_id is not None}

        sbt_repairs = []
        for je in invoice_jes:
            invoice_id = je.reference_id
            if not invoice_id:
                continue

            lines = [l for l in (getattr(je, 'lines', None) or []) if not getattr(l, 'is_deleted', False)]
            hits_sb = any(int(l.account_id) in sb_account_ids for l in lines if l.account_id is not None)
            if not hits_sb:
                continue

            if dry_run:
                # Check if SBTs already exist
                existing = SafeBoxTransaction.query.filter_by(invoice_id=invoice_id).count()
                sbt_repairs.append({
                    'invoice_id': invoice_id,
                    'journal_entry_id': je.id,
                    'existing_sbt_count': existing,
                    'action': 'skip' if existing > 0 else 'would_create',
                })
            else:
                created = _ensure_safe_box_transactions_for_invoice_je(
                    invoice_id=invoice_id,
                    journal_entry_id=je.id,
                    created_by=approved_by,
                )
                if created:
                    sbt_repairs.append({
                        'invoice_id': invoice_id,
                        'journal_entry_id': je.id,
                        'created_count': len(created),
                    })

        if not dry_run:
            # Recompute stored Account.balance_* for accounts in newly-posted
            # voucher JEs so the trial balance stays in sync.
            if voucher_je_repairs:
                try:
                    from accounting.balances import _recalculate_account_balances_for_accounts
                    _sb_repair_ids = set()
                    for _r in voucher_je_repairs:
                        _rje = JournalEntry.query.get(_r['journal_entry_id'])
                        if _rje:
                            _sb_repair_ids.update(
                                l.account_id for l in (_rje.lines or []) if l.account_id
                            )
                    if _sb_repair_ids:
                        _recalculate_account_balances_for_accounts(list(_sb_repair_ids))
                except Exception as _rc_exc:
                    print(f"⚠️ recalculate balances after safe-box repair skipped: {_rc_exc}")

            db.session.commit()

        return jsonify({
            'dry_run': dry_run,
            'scanned_invoice_jes': len(invoice_jes),
            'voucher_je_repairs': voucher_je_repairs,
            'total_voucher_je_repairs': len(voucher_je_repairs),
            'sbt_repairs': sbt_repairs,
            'total_sbt_repairs': len(sbt_repairs),
        })

    except Exception as exc:
        db.session.rollback()
        import traceback; traceback.print_exc()
        return jsonify({'error': 'repair_failed', 'message': str(exc)}), 500

@safe_boxes_bp.route('/safe-boxes', methods=['GET'])
@require_permission('safe_boxes.view')
def list_safe_boxes():
    """الحصول على جميع الخزائن أو حسب النوع"""
    safe_type = request.args.get('safe_type')  # cash, bank, gold, check, clearing
    is_active = request.args.get('is_active')
    karat = request.args.get('karat', type=int)
    
    query = SafeBox.query
    
    if safe_type:
        query = query.filter_by(safe_type=safe_type)
    
    if is_active is not None:
        query = query.filter_by(is_active=is_active.lower() == 'true')
    
    if karat:
        # For unified gold safes, allow karat-filtered queries to still return
        # the general (karat=None) safe.
        if (safe_type or '').strip().lower() == 'gold':
            query = query.filter((SafeBox.karat == karat) | (SafeBox.karat.is_(None)))
        else:
            query = query.filter_by(karat=karat)
    
    safe_boxes = query.order_by(SafeBox.is_default.desc(), SafeBox.name).all()
    
    include_account = request.args.get('include_account', 'false').lower() == 'true'
    include_balance = request.args.get('include_balance', 'true').lower() == 'true'

    live_by_id = {}
    if include_balance:
        live_by_id = live_balances_by_account_ids([
            sb.account_id for sb in safe_boxes if getattr(sb, 'account_id', None) is not None
        ])

    results = []
    for sb in safe_boxes:
        sb_dict = sb.to_dict(include_account=include_account, include_balance=False)
        if include_balance:
            live = live_by_id.get(int(sb.account_id)) if getattr(sb, 'account_id', None) is not None else None
            live = live if isinstance(live, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}

            balance = {
                'cash': round(float(live.get('cash') or 0.0), 2),
            }
            account = getattr(sb, 'account', None)
            if bool(getattr(account, 'tracks_weight', False)):
                w18 = float(live.get('18k') or 0.0)
                w21 = float(live.get('21k') or 0.0)
                w22 = float(live.get('22k') or 0.0)
                w24 = float(live.get('24k') or 0.0)
                balance['weight'] = {
                    '18k': round(w18, 3),
                    '21k': round(w21, 3),
                    '22k': round(w22, 3),
                    '24k': round(w24, 3),
                    'total': round(
                        convert_to_main_karat(w18, 18) +
                        convert_to_main_karat(w21, 21) +
                        convert_to_main_karat(w22, 22) +
                        convert_to_main_karat(w24, 24),
                        3
                    ),
                }
            sb_dict['balance'] = balance

        results.append(sb_dict)

    return jsonify(results)

@safe_boxes_bp.route('/safe-boxes/<int:safe_box_id>', methods=['GET'])
@require_permission('safe_boxes.view')
def get_safe_box(safe_box_id):
    """الحصول على خزينة محددة"""
    safe_box = SafeBox.query.get_or_404(safe_box_id)
    include_account = request.args.get('include_account', 'true').lower() == 'true'
    include_balance = request.args.get('include_balance', 'true').lower() == 'true'

    payload = safe_box.to_dict(include_account=include_account, include_balance=False)
    if include_balance:
        live = live_balances_by_account_ids([safe_box.account_id]).get(int(safe_box.account_id))
        live = live if isinstance(live, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}

        balance = {
            'cash': round(float(live.get('cash') or 0.0), 2),
        }
        account = getattr(safe_box, 'account', None)
        if bool(getattr(account, 'tracks_weight', False)):
            w18 = float(live.get('18k') or 0.0)
            w21 = float(live.get('21k') or 0.0)
            w22 = float(live.get('22k') or 0.0)
            w24 = float(live.get('24k') or 0.0)
            balance['weight'] = {
                '18k': round(w18, 3),
                '21k': round(w21, 3),
                '22k': round(w22, 3),
                '24k': round(w24, 3),
                'total': round(
                    convert_to_main_karat(w18, 18) +
                    convert_to_main_karat(w21, 21) +
                    convert_to_main_karat(w22, 22) +
                    convert_to_main_karat(w24, 24),
                    3
                ),
            }
        payload['balance'] = balance

    return jsonify(payload)

@safe_boxes_bp.route('/safe-boxes', methods=['POST'])
@require_permission('safe_boxes.create')
def create_safe_box():
    """إنشاء خزينة جديدة"""
    data = request.get_json() or {}
    
    # التحقق من الحقول المطلوبة
    if not data.get('name'):
        return jsonify({'error': 'اسم الخزينة مطلوب'}), 400
    
    if not data.get('safe_type'):
        return jsonify({'error': 'نوع الخزينة مطلوب'}), 400
    
    if not data.get('account_id'):
        return jsonify({'error': 'الحساب المرتبط مطلوب'}), 400
    
    # التحقق من وجود الحساب
    account = Account.query.get(data['account_id'])
    if not account:
        return jsonify({'error': 'الحساب المحدد غير موجود'}), 404

    # التحقق من خزينة الذهب: الحساب يجب أن يدعم تتبع الوزن (tracks_weight=True)
    karat = None
    if data['safe_type'] == 'gold':
        # ✅ في النظام الموحّد: خزائن الذهب متعددة العيارات دائماً (karat=None).
        # نسمح بتمرير karat من العميل للتوافق، لكن نتجاهله افتراضياً.
        force_karat_specific = (request.args.get('force_karat_specific') or '').strip().lower() == 'true'
        if force_karat_specific:
            karat_in = data.get('karat')
            if karat_in:
                try:
                    karat = int(karat_in)
                except Exception:
                    return jsonify({'error': 'العيار غير صالح'}), 400
                if karat not in (18, 21, 22, 24):
                    return jsonify({'error': 'العيار يجب أن يكون 18, 21, 22, أو 24'}), 400
            else:
                karat = None

        tracks_weight = bool(getattr(account, 'tracks_weight', False))
        if not tracks_weight:
            return jsonify({
                'error': 'الحساب المرتبط غير مناسب لخزنة الذهب',
                'details': 'يجب أن يتتبع الوزن (tracks_weight=True)'
            }), 400
    
    try:
        safe_box = SafeBox(
            name=data['name'],
            name_en=data.get('name_en'),
            safe_type=data['safe_type'],
            account_id=data['account_id'],
            karat=karat if data.get('safe_type') == 'gold' else data.get('karat'),
            bank_name=data.get('bank_name'),
            iban=data.get('iban'),
            swift_code=data.get('swift_code'),
            branch=data.get('branch'),
            is_active=data.get('is_active', True),
            is_default=data.get('is_default', False),
            notes=data.get('notes'),
            created_by=data.get('created_by'),
        )
        
        # إذا كانت افتراضية، إلغاء تفعيل الافتراضية من الخزائن الأخرى من نفس النوع
        if safe_box.is_default:
            SafeBox.query.filter_by(safe_type=safe_box.safe_type, is_default=True).update({'is_default': False})
        
        db.session.add(safe_box)
        db.session.commit()

        payload = safe_box.to_dict(include_account=True, include_balance=False)
        live = live_balances_by_account_ids([safe_box.account_id]).get(int(safe_box.account_id))
        live = live if isinstance(live, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
        balance = {
            'cash': round(float(live.get('cash') or 0.0), 2),
        }
        if bool(getattr(account, 'tracks_weight', False)):
            w18 = float(live.get('18k') or 0.0)
            w21 = float(live.get('21k') or 0.0)
            w22 = float(live.get('22k') or 0.0)
            w24 = float(live.get('24k') or 0.0)
            balance['weight'] = {
                '18k': round(w18, 3),
                '21k': round(w21, 3),
                '22k': round(w22, 3),
                '24k': round(w24, 3),
                'total': round(
                    convert_to_main_karat(w18, 18) +
                    convert_to_main_karat(w21, 21) +
                    convert_to_main_karat(w22, 22) +
                    convert_to_main_karat(w24, 24),
                    3
                ),
            }
        payload['balance'] = balance

        return jsonify(payload), 201
    
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء الخزينة: {str(e)}'}), 500

@safe_boxes_bp.route('/safe-boxes/<int:safe_box_id>', methods=['PUT'])
@require_permission('safe_boxes.edit')
def update_safe_box(safe_box_id):
    """تحديث خزينة"""
    safe_box = SafeBox.query.get_or_404(safe_box_id)
    data = request.get_json() or {}
    
    try:
        if 'name' in data:
            safe_box.name = data['name']
        
        if 'name_en' in data:
            safe_box.name_en = data['name_en']
        
        if 'safe_type' in data:
            safe_box.safe_type = data['safe_type']
        
        if 'account_id' in data:
            account = Account.query.get(data['account_id'])
            if not account:
                return jsonify({'error': 'الحساب المحدد غير موجود'}), 404
            safe_box.account_id = data['account_id']

            pass  # account updated
        
        if 'karat' in data:
            # ✅ في النظام الموحّد: خزائن الذهب متعددة العيارات دائماً (karat=None).
            # نسمح بالوضع القديم فقط عند force_karat_specific=true.
            effective_type_now = (safe_box.safe_type or '').strip().lower()
            if effective_type_now == 'gold':
                force_karat_specific = (request.args.get('force_karat_specific') or '').strip().lower() == 'true'
                if not force_karat_specific:
                    safe_box.karat = None
                else:
                    karat_value = data['karat']
                    if karat_value:
                        try:
                            karat_value = int(karat_value)
                            if karat_value not in (18, 21, 22, 24):
                                return jsonify({'error': 'العيار يجب أن يكون 18, 21, 22, أو 24'}), 400
                        except Exception:
                            return jsonify({'error': 'العيار غير صالح'}), 400
                    else:
                        karat_value = None
                    safe_box.karat = karat_value
            else:
                karat_value = data['karat']
                if karat_value:
                    try:
                        karat_value = int(karat_value)
                        if karat_value not in (18, 21, 22, 24):
                            return jsonify({'error': 'العيار يجب أن يكون 18, 21, 22, أو 24'}), 400
                    except Exception:
                        return jsonify({'error': 'العيار غير صالح'}), 400
                else:
                    karat_value = None
                safe_box.karat = karat_value

        # ✅ تحقق إضافي: خزنة الذهب تحتاج حساباً يدعم تتبع الوزن
        effective_type = (safe_box.safe_type or '').strip().lower()
        if effective_type == 'gold':
            account = Account.query.get(safe_box.account_id)
            if not account:
                return jsonify({'error': 'الحساب المحدد غير موجود'}), 404
            tracks_weight = bool(getattr(account, 'tracks_weight', False))

            if not tracks_weight:
                return jsonify({
                    'error': 'الحساب المرتبط غير مناسب لخزنة الذهب',
                    'details': 'يجب أن يتتبع الوزن (tracks_weight=True)'
                }), 400

            # في الوضع الموحّد: امسح العيار دائماً (إلا إذا تم فرض خلاف ذلك عبر query param)
            force_karat_specific = (request.args.get('force_karat_specific') or '').strip().lower() == 'true'
            if not force_karat_specific:
                safe_box.karat = None
        else:
            # لو تغير النوع من ذهب إلى غير ذهب، امسح العيار للحفاظ على الاتساق.
            safe_box.karat = None

        
        if 'bank_name' in data:
            safe_box.bank_name = data['bank_name']
        
        if 'iban' in data:
            safe_box.iban = data['iban']
        
        if 'swift_code' in data:
            safe_box.swift_code = data['swift_code']
        
        if 'branch' in data:
            safe_box.branch = data['branch']
        
        if 'is_active' in data:
            safe_box.is_active = data['is_active']
        
        if 'is_default' in data:
            is_default_value = bool(data['is_default'])
            if is_default_value:
                # إلغاء تفعيل الافتراضية من الخزائن الأخرى من نفس النوع
                SafeBox.query.filter(
                    SafeBox.safe_type == safe_box.safe_type,
                    SafeBox.id != safe_box_id,
                    SafeBox.is_default == True
                ).update({'is_default': False})
                safe_box.is_default = True
            else:
                safe_box.is_default = False
        
        if 'notes' in data:
            safe_box.notes = data['notes']
        
        db.session.commit()

        payload = safe_box.to_dict(include_account=True, include_balance=False)
        live = live_balances_by_account_ids([safe_box.account_id]).get(int(safe_box.account_id))
        live = live if isinstance(live, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
        balance = {
            'cash': round(float(live.get('cash') or 0.0), 2),
        }
        account = Account.query.get(safe_box.account_id)
        if bool(getattr(account, 'tracks_weight', False)):
            w18 = float(live.get('18k') or 0.0)
            w21 = float(live.get('21k') or 0.0)
            w22 = float(live.get('22k') or 0.0)
            w24 = float(live.get('24k') or 0.0)
            balance['weight'] = {
                '18k': round(w18, 3),
                '21k': round(w21, 3),
                '22k': round(w22, 3),
                '24k': round(w24, 3),
                'total': round(
                    convert_to_main_karat(w18, 18) +
                    convert_to_main_karat(w21, 21) +
                    convert_to_main_karat(w22, 22) +
                    convert_to_main_karat(w24, 24),
                    3
                ),
            }
        payload['balance'] = balance

        return jsonify(payload)
    
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث الخزينة: {str(e)}'}), 500

@safe_boxes_bp.route('/safe-boxes/<int:safe_box_id>', methods=['DELETE'])
@require_permission('safe_boxes.delete')
def delete_safe_box(safe_box_id):
    """حذف خزينة"""
    safe_box = SafeBox.query.get_or_404(safe_box_id)

    # منع حذف الخزينة إذا كانت مرتبطة بكيانات أخرى (Restrict)
    # ملاحظة: هذا الفحص مهم خصوصاً على SQLite/قواعد قديمة حيث قد لا توجد قيود FK فعلية.
    try:
        linked_employees = Employee.query.filter(Employee.gold_safe_box_id == safe_box_id).count()
        linked_transactions = SafeBoxTransaction.query.filter(SafeBoxTransaction.safe_box_id == safe_box_id).count()
        linked_invoices = Invoice.query.filter(Invoice.safe_box_id == safe_box_id).count()
        linked_payment_methods = PaymentMethod.query.filter(PaymentMethod.default_safe_box_id == safe_box_id).count()

        if any(v > 0 for v in [
            linked_employees,
            linked_transactions,
            linked_invoices,
            linked_payment_methods,
        ]):
            return jsonify({
                'error': 'cannot_delete_safe_box_in_use',
                'message': 'لا يمكن حذف الخزينة لأنها مرتبطة بموظف/عمليات/فواتير/وسائل دفع',
                'details': {
                    'employees_linked': int(linked_employees),
                    'transactions_linked': int(linked_transactions),
                    'invoices_linked': int(linked_invoices),
                    'payment_methods_linked': int(linked_payment_methods),
                },
            }), 400
    except Exception:
        # إذا فشل الفحص لأي سبب، الأفضل عدم السماح بالحذف بدلاً من حذف بيانات مهمة.
        return jsonify({
            'error': 'cannot_delete_safe_box_validation_failed',
            'message': 'تعذر التحقق من ارتباطات الخزينة قبل الحذف',
        }), 400
    
    try:
        db.session.delete(safe_box)
        db.session.commit()
        return jsonify({'message': 'تم حذف الخزينة بنجاح'})
    
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'فشل حذف الخزينة: {str(e)}'}), 500

@safe_boxes_bp.route('/safe-boxes/default/<safe_type>', methods=['GET'])
@require_permission('safe_boxes.view')
def get_default_safe_box(safe_type):
    """الحصول على الخزينة الافتراضية حسب النوع"""
    safe_box = SafeBox.get_default_by_type(safe_type)
    
    if not safe_box:
        return jsonify({'error': f'لا توجد خزينة افتراضية من نوع {safe_type}'}), 404

    payload = safe_box.to_dict(include_account=True, include_balance=False)
    live = live_balances_by_account_ids([safe_box.account_id]).get(int(safe_box.account_id))
    live = live if isinstance(live, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
    balance = {
        'cash': round(float(live.get('cash') or 0.0), 2),
    }
    account = getattr(safe_box, 'account', None)
    if bool(getattr(account, 'tracks_weight', False)):
        w18 = float(live.get('18k') or 0.0)
        w21 = float(live.get('21k') or 0.0)
        w22 = float(live.get('22k') or 0.0)
        w24 = float(live.get('24k') or 0.0)
        balance['weight'] = {
            '18k': round(w18, 3),
            '21k': round(w21, 3),
            '22k': round(w22, 3),
            '24k': round(w24, 3),
            'total': round(
                convert_to_main_karat(w18, 18) +
                convert_to_main_karat(w21, 21) +
                convert_to_main_karat(w22, 22) +
                convert_to_main_karat(w24, 24),
                3
            ),
        }
    payload['balance'] = balance

    return jsonify(payload)

@safe_boxes_bp.route('/safe-boxes/gold/<int:karat>', methods=['GET'])
@require_permission('safe_boxes.view')
def get_gold_safe_box_by_karat(karat):
    """الحصول على خزينة الذهب حسب العيار"""
    safe_box = SafeBox.get_gold_safe_by_karat(karat)
    
    if not safe_box:
        return jsonify({'error': f'لا توجد خزينة ذهب لعيار {karat}'}), 404

    payload = safe_box.to_dict(include_account=True, include_balance=False)
    live = live_balances_by_account_ids([safe_box.account_id]).get(int(safe_box.account_id))
    live = live if isinstance(live, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
    balance = {
        'cash': round(float(live.get('cash') or 0.0), 2),
    }
    account = getattr(safe_box, 'account', None)
    if bool(getattr(account, 'tracks_weight', False)):
        w18 = float(live.get('18k') or 0.0)
        w21 = float(live.get('21k') or 0.0)
        w22 = float(live.get('22k') or 0.0)
        w24 = float(live.get('24k') or 0.0)
        balance['weight'] = {
            '18k': round(w18, 3),
            '21k': round(w21, 3),
            '22k': round(w22, 3),
            '24k': round(w24, 3),
            'total': round(
                convert_to_main_karat(w18, 18) +
                convert_to_main_karat(w21, 21) +
                convert_to_main_karat(w22, 22) +
                convert_to_main_karat(w24, 24),
                3
            ),
        }
    payload['balance'] = balance

    return jsonify(payload)

@safe_boxes_bp.route('/safe-boxes/gold/unify', methods=['POST'])
@require_permission('safe_boxes.edit')
def unify_gold_safe_boxes():
    """Unify legacy karat-specific gold safe boxes into a single multi-karat safe.

    This helps move from the old design (one safe per karat) to the new design
    (one safe that tracks all karats).

    Body JSON (optional):
      - target_safe_box_id: int
      - dry_run: bool (default false)

    Effects when not dry_run:
      - Ensures target safe has karat=None and is_default=True
      - Reassigns SafeBoxTransaction/Invoice/PaymentMethod/Employee references
        from other karat-specific gold safes to target
      - Deactivates the merged legacy safes
    """

    data = request.get_json(silent=True) or {}
    dry_run = bool(data.get('dry_run', False))
    target_id = data.get('target_safe_box_id')

    if target_id is not None:
        try:
            target_id = int(target_id)
        except Exception:
            return jsonify({'error': 'invalid_target_safe_box_id'}), 400

    # Pick target
    target = None
    if target_id:
        target = SafeBox.query.get(target_id)
        if not target:
            return jsonify({'error': 'target_safe_box_not_found'}), 404
        if (target.safe_type or '').strip().lower() != 'gold':
            return jsonify({'error': 'target_safe_box_must_be_gold'}), 400
    else:
        target = SafeBox.query.filter_by(safe_type='gold', karat=None, is_active=True).order_by(SafeBox.is_default.desc(), SafeBox.id.asc()).first()
        if not target:
            target = SafeBox.query.filter_by(safe_type='gold', is_active=True).order_by(SafeBox.is_default.desc(), SafeBox.id.asc()).first()

    if not target:
        return jsonify({'error': 'no_gold_safe_boxes_found'}), 404

    legacy = (
        SafeBox.query
        .filter(SafeBox.safe_type == 'gold', SafeBox.id != target.id, SafeBox.karat.isnot(None))
        .all()
    )

    summary = {
        'dry_run': dry_run,
        'target_safe_box_id': int(target.id),
        'target_name': target.name,
        'legacy_safe_boxes': [
            {'id': int(sb.id), 'name': sb.name, 'karat': sb.karat, 'is_active': bool(sb.is_active)}
            for sb in legacy
        ],
        'moved': {
            'safe_box_transactions': 0,
            'invoices': 0,
            'payment_methods': 0,
            'employees': 0,
        },
        'deactivated_safe_boxes': 0,
    }

    if dry_run:
        return jsonify({'status': 'ok', 'summary': summary}), 200

    try:
        # Ensure target is the unified safe
        target.karat = None
        target.is_active = True

        # Make it default gold safe (and clear others)
        SafeBox.query.filter(SafeBox.safe_type == 'gold', SafeBox.id != target.id, SafeBox.is_default == True).update({'is_default': False})
        target.is_default = True

        for sb in legacy:
            # Rewire references
            summary['moved']['safe_box_transactions'] += int(
                SafeBoxTransaction.query.filter_by(safe_box_id=sb.id).update({'safe_box_id': target.id})
            )
            summary['moved']['invoices'] += int(
                Invoice.query.filter_by(safe_box_id=sb.id).update({'safe_box_id': target.id})
            )
            summary['moved']['payment_methods'] += int(
                PaymentMethod.query.filter_by(default_safe_box_id=sb.id).update({'default_safe_box_id': target.id})
            )
            summary['moved']['employees'] += int(
                Employee.query.filter_by(gold_safe_box_id=sb.id).update({'gold_safe_box_id': target.id})
            )

            # Deactivate legacy safe
            sb.is_active = False
            sb.is_default = False
            try:
                note = (sb.notes or '').strip()
                prefix = 'تم دمجها في خزينة ذهب موحّدة'
                sb.notes = (note + ('\n' if note else '') + prefix + f' (target_id={target.id})')
            except Exception:
                pass
            summary['deactivated_safe_boxes'] += 1

        db.session.commit()
        return jsonify({'status': 'ok', 'summary': summary}), 200

    except Exception as e:
        db.session.rollback()
        return jsonify({'status': 'error', 'message': str(e)}), 500

@safe_boxes_bp.route('/safe-boxes/transfer-voucher', methods=['POST'])
@require_permission('safe_boxes.edit')
def create_safe_box_transfer_voucher():
    """Create a safe-box transfer voucher and update the SafeBox ledger immediately.

    Supports:
    - Gold transfer between gold safes (weights by karat)
    - Cash transfer between non-gold safes (cash/bank/check/clearing) using amount_cash

    Body JSON:
        - from_safe_box_id: int (required)
        - to_safe_box_id: int (required)
        - Gold mode:
                - weights: {"24k": float, "22k": float, "21k": float, "18k": float} (optional)
                    OR weight_24k/weight_22k/weight_21k/weight_18k (optional)
        - Cash mode:
                - amount_cash: float (required)  (alias: amount)
        - date: ISO datetime (optional)
        - notes: str (optional)
        - created_by / approved_by: str (optional)

    Result: creates an approved adjustment Voucher + JournalEntry + SafeBoxTransaction rows (out/in).
    """

    data = request.get_json(silent=True) or {}
    from_safe_box_id = data.get('from_safe_box_id')
    to_safe_box_id = data.get('to_safe_box_id')

    if not from_safe_box_id or not to_safe_box_id:
        return jsonify({'error': 'from_safe_box_id_and_to_safe_box_id_required'}), 400

    try:
        from_safe_box_id = int(from_safe_box_id)
        to_safe_box_id = int(to_safe_box_id)
    except Exception:
        return jsonify({'error': 'invalid_safe_box_id'}), 400

    if from_safe_box_id == to_safe_box_id:
        return jsonify({'error': 'cannot_transfer_to_same_safe_box'}), 400

    from_safe = SafeBox.query.get_or_404(from_safe_box_id)
    to_safe = SafeBox.query.get_or_404(to_safe_box_id)

    from_type = (from_safe.safe_type or '').strip().lower()
    to_type = (to_safe.safe_type or '').strip().lower()

    if not bool(getattr(from_safe, 'is_active', True)) or not bool(getattr(to_safe, 'is_active', True)):
        return jsonify({'error': 'safe_box_inactive'}), 400

    # Prevent mixing gold transfer with cash transfer in a single request.
    if ('gold' in {from_type, to_type}) and not (from_type == 'gold' and to_type == 'gold'):
        return jsonify({'error': 'cannot_mix_gold_and_cash_safe_boxes'}), 400

    def _f(v):
        try:
            return float(v or 0.0)
        except Exception:
            return 0.0

    is_gold_transfer = (from_type == 'gold' and to_type == 'gold')

    # ------------------------------------------------------------------
    # Gold transfer (weights)
    # ------------------------------------------------------------------
    if is_gold_transfer:
        weights = data.get('weights') or {}

        w_24 = _f(weights.get('24k') if isinstance(weights, dict) else None)
        w_22 = _f(weights.get('22k') if isinstance(weights, dict) else None)
        w_21 = _f(weights.get('21k') if isinstance(weights, dict) else None)
        w_18 = _f(weights.get('18k') if isinstance(weights, dict) else None)

        # Allow alternate flat fields
        if w_24 == 0.0:
            w_24 = _f(data.get('weight_24k'))
        if w_22 == 0.0:
            w_22 = _f(data.get('weight_22k'))
        if w_21 == 0.0:
            w_21 = _f(data.get('weight_21k'))
        if w_18 == 0.0:
            w_18 = _f(data.get('weight_18k'))

        for v in (w_24, w_22, w_21, w_18):
            if v < 0:
                return jsonify({'error': 'negative_weight_not_allowed'}), 400

        if (w_24 + w_22 + w_21 + w_18) <= 0:
            return jsonify({'error': 'no_weights_provided'}), 400

        # Compute current source balance from ledger and enforce sufficiency.
        q = SafeBoxTransaction.query.filter_by(safe_box_id=from_safe_box_id)
        w_in = {
            '18k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_18k), 0.0)).filter(SafeBoxTransaction.direction == 'in').scalar() or 0.0),
            '21k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_21k), 0.0)).filter(SafeBoxTransaction.direction == 'in').scalar() or 0.0),
            '22k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_22k), 0.0)).filter(SafeBoxTransaction.direction == 'in').scalar() or 0.0),
            '24k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_24k), 0.0)).filter(SafeBoxTransaction.direction == 'in').scalar() or 0.0),
        }
        w_out = {
            '18k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_18k), 0.0)).filter(SafeBoxTransaction.direction == 'out').scalar() or 0.0),
            '21k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_21k), 0.0)).filter(SafeBoxTransaction.direction == 'out').scalar() or 0.0),
            '22k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_22k), 0.0)).filter(SafeBoxTransaction.direction == 'out').scalar() or 0.0),
            '24k': float(q.with_entities(func.coalesce(func.sum(SafeBoxTransaction.weight_24k), 0.0)).filter(SafeBoxTransaction.direction == 'out').scalar() or 0.0),
        }
        w_bal = {k: float(w_in.get(k, 0.0)) - float(w_out.get(k, 0.0)) for k in ['18k', '21k', '22k', '24k']}
        eps = 1e-6
        if (w_24 - (w_bal.get('24k', 0.0) or 0.0)) > eps:
            return jsonify({'error': 'insufficient_balance_24k', 'available': round(w_bal.get('24k', 0.0), 3)}), 400
        if (w_22 - (w_bal.get('22k', 0.0) or 0.0)) > eps:
            return jsonify({'error': 'insufficient_balance_22k', 'available': round(w_bal.get('22k', 0.0), 3)}), 400
        if (w_21 - (w_bal.get('21k', 0.0) or 0.0)) > eps:
            return jsonify({'error': 'insufficient_balance_21k', 'available': round(w_bal.get('21k', 0.0), 3)}), 400
        if (w_18 - (w_bal.get('18k', 0.0) or 0.0)) > eps:
            return jsonify({'error': 'insufficient_balance_18k', 'available': round(w_bal.get('18k', 0.0), 3)}), 400

    # ------------------------------------------------------------------
    # Cash transfer (amount_cash)
    # ------------------------------------------------------------------
    else:
        amount_cash = _f(data.get('amount_cash') or data.get('amount') or data.get('cash_amount'))
        if amount_cash <= 0:
            return jsonify({'error': 'amount_cash_required'}), 400

        if amount_cash < 0:
            return jsonify({'error': 'negative_amount_not_allowed'}), 400

        # Use live GL balance (same source used by safe-box balances UI)
        # to avoid false "insufficient" when historical SBT rows are incomplete.
        cash_bal = 0.0
        try:
            live = (
                live_balances_by_account_ids([int(from_safe.account_id)])
                .get(int(from_safe.account_id), {})
            )
            cash_bal = float((live or {}).get('cash') or 0.0)
        except Exception:
            cash_bal = 0.0

        eps = 1e-6
        if (amount_cash - cash_bal) > eps:
            return jsonify({'error': 'insufficient_cash_balance', 'available': round(float(cash_bal), 2)}), 400

        # Reuse existing variables to minimize changes below.
        w_24 = w_22 = w_21 = w_18 = 0.0

    created_by = (data.get('approved_by') or data.get('created_by') or 'system')
    notes = (data.get('notes') or '').strip() or None

    try:
        voucher_dt = datetime.fromisoformat(data.get('date')) if data.get('date') else datetime.now()
    except Exception:
        return jsonify({'error': 'invalid_date'}), 400

    lines = []
    if is_gold_transfer:
        # Build balanced gold account lines (credit from_safe.account, debit to_safe.account)
        def _line(account_id: int, *, line_type: str, karat: int, amount: float):
            return VoucherAccountLine(
                account_id=account_id,
                line_type=line_type,
                amount_type='gold',
                amount=float(amount),
                karat=float(karat),
            )

        if w_24 > 0:
            lines.append(_line(to_safe.account_id, line_type='debit', karat=24, amount=w_24))
            lines.append(_line(from_safe.account_id, line_type='credit', karat=24, amount=w_24))
        if w_22 > 0:
            lines.append(_line(to_safe.account_id, line_type='debit', karat=22, amount=w_22))
            lines.append(_line(from_safe.account_id, line_type='credit', karat=22, amount=w_22))
        if w_21 > 0:
            lines.append(_line(to_safe.account_id, line_type='debit', karat=21, amount=w_21))
            lines.append(_line(from_safe.account_id, line_type='credit', karat=21, amount=w_21))
        if w_18 > 0:
            lines.append(_line(to_safe.account_id, line_type='debit', karat=18, amount=w_18))
            lines.append(_line(from_safe.account_id, line_type='credit', karat=18, amount=w_18))
    else:
        # Cash transfer: debit to_safe, credit from_safe.
        amount_cash = float(amount_cash)
        lines.append(VoucherAccountLine(
            account_id=to_safe.account_id,
            line_type='debit',
            amount_type='cash',
            amount=amount_cash,
        ))
        lines.append(VoucherAccountLine(
            account_id=from_safe.account_id,
            line_type='credit',
            amount_type='cash',
            amount=amount_cash,
        ))

    try:
        voucher_number = generate_voucher_number('adjustment', voucher_date=voucher_dt)

        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='adjustment',
            date=voucher_dt,
            party_type=None,
            description=(
                f"تحويل خزنة ذهب: {from_safe.name} → {to_safe.name}"
                if is_gold_transfer
                else f"تحويل خزنة: {from_safe.name} → {to_safe.name}"
            ),
            amount_cash=(0.0 if is_gold_transfer else float(amount_cash)),
            amount_gold=(float(w_24 + w_22 + w_21 + w_18) if is_gold_transfer else 0.0),
            reference_type='manual',
            reference_number=None,
            notes=notes,
            created_by=created_by,
            status='pending',
        )
        db.session.add(voucher)
        db.session.flush()

        for l in lines:
            l.voucher_id = voucher.id
            db.session.add(l)

        # Approve/post immediately -- born approved, born posted
        # (APPROVED-ENTRY-001): raises if no entry.
        journal_entry = post_entry_of_approved_voucher(voucher, posted_by=created_by)

        voucher.status = 'approved'
        voucher.approved_at = datetime.now()
        voucher.approved_by = created_by
        voucher.journal_entry_id = journal_entry.id

        _append_safe_transactions_for_voucher(voucher, created_by=created_by)

        # Stamp per-karat stones data onto SBTs (if provided)
        if is_gold_transfer:
            _st_raw = data.get('stones') or {}
            _sf2 = lambda v: max(0.0, float(v or 0))
            _st18 = _sf2(_st_raw.get('18k'))
            _st21 = _sf2(_st_raw.get('21k'))
            _st22 = _sf2(_st_raw.get('22k'))
            _st24 = _sf2(_st_raw.get('24k'))
            _st_total = _st18 + _st21 + _st22 + _st24
            if _st_total > 0:
                _sbts = SafeBoxTransaction.query.filter_by(
                    ref_id=voucher.id, ref_type='voucher'
                ).all()
                for _sbt in _sbts:
                    if _sbt.safe_box_id == from_safe.id and _sbt.direction == 'out':
                        _sbt.stones_18k    = _st18
                        _sbt.stones_21k    = _st21
                        _sbt.stones_22k    = _st22
                        _sbt.stones_24k    = _st24
                        _sbt.stones_weight = _st_total
                    elif _sbt.safe_box_id == to_safe.id and _sbt.direction == 'in':
                        _sbt.stones_18k    = _st18
                        _sbt.stones_21k    = _st21
                        _sbt.stones_22k    = _st22
                        _sbt.stones_24k    = _st24
                        _sbt.stones_weight = _st_total

        db.session.commit()

        return jsonify({
            'message': 'تم إنشاء سند التحويل وتحديث الخزائن بنجاح',
            'voucher': voucher.to_dict(),
            'journal_entry': {
                'id': journal_entry.id,
                'entry_number': journal_entry.entry_number,
                'date': journal_entry.date.isoformat() if journal_entry.date else None,
            },
            'transfer': {
                'from_safe_box_id': from_safe.id,
                'to_safe_box_id': to_safe.id,
                'type': ('gold' if is_gold_transfer else 'cash'),
                **({'amount_cash': round(float(amount_cash), 2)} if not is_gold_transfer else {}),
                **({
                    'weights': {
                        '24k': round(float(w_24), 3),
                        '22k': round(float(w_22), 3),
                        '21k': round(float(w_21), 3),
                        '18k': round(float(w_18), 3),
                    },
                } if is_gold_transfer else {}),
            },
        }), 201
    except ValueError as e:
        db.session.rollback()
        msg = str(e)
        if msg.startswith('karat_mismatch_for_safe_box:'):
            return jsonify({
                'error': 'karat_mismatch_for_safe_box',
                'message': 'لا يمكن تنفيذ التحويل: عيار الحركة لا يتطابق مع عيار الخزنة (الخزنة مخصصة لعيار واحد)',
                'details': msg,
            }), 400
        return jsonify({'error': 'validation_error', 'message': msg}), 400
    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'safe_box_transfer_voucher_failed', 'message': str(e)}), 500

# =========================================================================
# Karat Correction within same Gold Safe Box
# =========================================================================

@safe_boxes_bp.route('/safe-boxes/<int:safe_box_id>/correct-karat', methods=['POST'])
@require_permission('safe_boxes.edit')
def correct_safe_box_karat(safe_box_id):
    """تصحيح عيار خاطئ داخل نفس الخزينة الذهبية.

    يُنقَل وزن X غرام من عيار قديم (مسجَّل خطأً) إلى عيار صحيح
    داخل نفس الخزينة، دون أي تحويل حسابي للوزن.

    Body JSON:
        - from_karat: int  (18 | 21 | 22 | 24)  — العيار الخاطئ المسجَّل
        - to_karat:   int  (18 | 21 | 22 | 24)  — العيار الصحيح
        - weight:     float  (غرام، موجب)
        - notes:      str  (اختياري)  — سبب التصحيح
    """
    data = request.get_json(silent=True) or {}

    _valid_karats = {18, 21, 22, 24}

    try:
        from_karat = int(data.get('from_karat', 0))
        to_karat   = int(data.get('to_karat', 0))
    except (TypeError, ValueError):
        return jsonify({'error': 'invalid_karat'}), 400

    if from_karat not in _valid_karats or to_karat not in _valid_karats:
        return jsonify({'error': 'invalid_karat', 'allowed': list(_valid_karats)}), 400

    if from_karat == to_karat:
        return jsonify({'error': 'same_karat'}), 400

    try:
        weight = float(data.get('weight') or 0)
    except (TypeError, ValueError):
        weight = 0.0
    if weight <= 0:
        return jsonify({'error': 'invalid_weight'}), 400

    notes = (data.get('notes') or '').strip() or None

    try:
        safe = SafeBox.query.filter_by(id=safe_box_id).first()
        if safe is None:
            return jsonify({'error': 'safe_box_not_found'}), 404
        if (safe.safe_type or '').lower() != 'gold':
            return jsonify({'error': 'not_a_gold_safe'}), 400
        if not bool(getattr(safe, 'is_active', True)):
            return jsonify({'error': 'safe_box_inactive'}), 400

        # --- التحقق من رصيد العيار المصدر ---
        from_col = f'weight_{from_karat}k'
        q = SafeBoxTransaction.query.filter_by(safe_box_id=safe_box_id)
        col_attr = getattr(SafeBoxTransaction, from_col)
        w_in  = float(q.with_entities(func.coalesce(func.sum(col_attr), 0.0))
                        .filter(SafeBoxTransaction.direction == 'in').scalar() or 0.0)
        w_out = float(q.with_entities(func.coalesce(func.sum(col_attr), 0.0))
                        .filter(SafeBoxTransaction.direction == 'out').scalar() or 0.0)
        available = round(w_in - w_out, 6)

        if weight > available + 1e-6:
            return jsonify({
                'error': 'insufficient_balance',
                'karat': from_karat,
                'available': round(available, 3),
            }), 400

        created_by = getattr(getattr(g, 'current_user', None), 'username', None) or 'system'
    except Exception as pre_err:
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'pre_validation_failed', 'message': str(pre_err)}), 500

    try:
        voucher_dt = datetime.now()
        voucher_number = generate_voucher_number('adjustment', voucher_date=voucher_dt)

        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='adjustment',
            date=voucher_dt,
            party_type=None,
            description=f"تصحيح عيار: {from_karat}k → {to_karat}k ({weight:.3f} جم) — {safe.name}",
            amount_cash=0.0,
            amount_gold=round(weight, 4),
            reference_type='manual',
            reference_number=None,
            notes=notes,
            created_by=created_by,
            status='pending',
        )
        db.session.add(voucher)
        db.session.flush()

        # قيد محاسبي: مدين بالعيار الجديد — دائن بالعيار القديم (نفس الحساب)
        for lt, karat_val in (('debit', float(to_karat)), ('credit', float(from_karat))):
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=safe.account_id,
                line_type=lt,
                amount_type='gold',
                amount=weight,
                karat=karat_val,
            ))

        # Born approved, born posted (APPROVED-ENTRY-001): raises if no entry.
        journal_entry = post_entry_of_approved_voucher(voucher, posted_by=created_by)

        voucher.status = 'approved'
        voucher.approved_at = datetime.now()
        voucher.approved_by = created_by
        voucher.journal_entry_id = journal_entry.id

        # حركتان في ledger الخزينة: خروج من العيار القديم، دخول للعيار الجديد
        kw_out = {'amount_cash': 0.0, from_col: round(weight, 6)}
        kw_in  = {'amount_cash': 0.0, f'weight_{to_karat}k': round(weight, 6)}

        db.session.add(SafeBoxTransaction(
            safe_box_id=safe_box_id,
            direction='out',
            ref_type='voucher',
            ref_id=voucher.id,
            created_by=created_by,
            notes=f'تصحيح عيار — خروج {from_karat}k',
            **kw_out,
        ))
        db.session.add(SafeBoxTransaction(
            safe_box_id=safe_box_id,
            direction='in',
            ref_type='voucher',
            ref_id=voucher.id,
            created_by=created_by,
            notes=f'تصحيح عيار — دخول {to_karat}k',
            **kw_in,
        ))

        db.session.commit()

        return jsonify({
            'message': 'تم تصحيح العيار بنجاح',
            'voucher': voucher.to_dict(),
            'correction': {
                'safe_box_id': safe_box_id,
                'safe_name': safe.name,
                'from_karat': from_karat,
                'to_karat': to_karat,
                'weight': round(weight, 3),
            },
        }), 201

    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'karat_correction_failed', 'message': str(e)}), 500

# =========================================================================
# Melting / Renewal Operation  (تكسير وتجديد)
# =========================================================================

