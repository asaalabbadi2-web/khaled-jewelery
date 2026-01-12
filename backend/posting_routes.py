"""
نظام التحكم بالترحيل (Posting Control System)
================================================

هذا الملف يوفر endpoints للتحكم بترحيل الفواتير والقيود:

1. ترحيل فاتورة واحدة أو مجموعة
2. إلغاء ترحيل فاتورة
3. ترحيل قيد واحد أو مجموعة
4. إلغاء ترحيل قيد
5. عرض الفواتير/القيود غير المرحلة

الاستخدام:
-----------
from posting_routes import posting_bp
app.register_blueprint(posting_bp, url_prefix='/api')
"""

from flask import Blueprint, request, jsonify, g
from datetime import datetime, timedelta
from models import (
    db,
    Invoice,
    JournalEntry,
    Account,
    Customer,
    Supplier,
    AuditLog,
    Settings,
    SystemAlert,
    PaymentType,
    PaymentMethod,
    SafeBox,
    SafeBoxTransaction,
)
from sqlalchemy import func, case, or_, and_
import json
from auth_decorators import require_permission, optional_auth

posting_bp = Blueprint('posting', __name__)


# ==========================================
# 🧾 إغلاق اليومية (Shift Closing)
# ==========================================


def _direction_for_invoice_gold(invoice_type: str) -> str:
    """Map invoice type to gold movement direction (in/out)."""
    t = (invoice_type or '').strip()
    if 'مورد' in t and 'شراء' in t:
        if 'مرتجع' in t:
            t = 'مرتجع شراء (مورد)'
        else:
            t = 'شراء'
    if t == 'بيع':
        return 'out'
    if t == 'مرتجع بيع':
        return 'in'
    if t in ('شراء من عميل', 'شراء'):
        return 'in'
    if t in ('مرتجع شراء', 'مرتجع شراء (مورد)'):
        return 'out'
    # Default: no-op direction is safer as 'out'/'in' both change inventory;
    # but we only create rows when weights exist, so choose 'out' only for explicit sale.
    return 'in'


def _append_safe_transactions_for_invoice_gold(invoice: Invoice, created_by: str = None):
    """Append SafeBoxTransaction rows representing gold inventory movements for an invoice.

    Source weights:
    - Prefer InvoiceKaratLine (bulk purchases).
    - Fallback to InvoiceItem weight * quantity.

    Ledger is append-only; reversal is handled by a separate helper.
    """
    if not invoice or not getattr(invoice, 'id', None):
        return []

    # Avoid duplicates
    existing = (
        SafeBoxTransaction.query.filter_by(ref_type='invoice_gold', ref_id=invoice.id)
        .order_by(SafeBoxTransaction.id.desc())
        .first()
    )
    if existing:
        return []

    def _to_float(v):
        try:
            if v in (None, '', False):
                return 0.0
            return float(v)
        except Exception:
            return 0.0

    weights_by_karat = {18: 0.0, 21: 0.0, 22: 0.0, 24: 0.0}

    # Prefer explicit karat lines when available
    karat_lines = getattr(invoice, 'karat_lines', None) or []
    used_karat_lines = False
    try:
        for line in karat_lines:
            karat = int(float(getattr(line, 'karat', 21) or 21))
            grams = _to_float(getattr(line, 'weight_grams', 0.0))
            if grams <= 0:
                continue
            if karat not in weights_by_karat:
                karat = 21
            weights_by_karat[karat] += grams
            used_karat_lines = True
    except Exception:
        used_karat_lines = False

    if not used_karat_lines:
        items = getattr(invoice, 'items', None) or []
        for inv_item in items:
            qty = getattr(inv_item, 'quantity', None) or 1
            try:
                qty = int(qty)
            except Exception:
                qty = 1
            if qty <= 0:
                qty = 1

            karat_val = getattr(inv_item, 'karat', None)
            if karat_val in (None, '', False) and getattr(inv_item, 'item', None):
                karat_val = getattr(inv_item.item, 'karat', None)

            try:
                karat = int(float(karat_val or 21))
            except Exception:
                karat = 21
            if karat not in weights_by_karat:
                karat = 21

            weight_per_unit = getattr(inv_item, 'weight', None)
            if weight_per_unit in (None, '', False) and getattr(inv_item, 'item', None):
                weight_per_unit = getattr(inv_item.item, 'weight', None)
            grams = _to_float(weight_per_unit) * float(qty)
            if grams <= 0:
                continue
            weights_by_karat[karat] += grams

    direction = _direction_for_invoice_gold(getattr(invoice, 'invoice_type', None))
    invoice_number = getattr(invoice, 'invoice_number', None) or str(getattr(invoice, 'id', ''))

    created = []
    for karat, grams in weights_by_karat.items():
        if grams <= 0.0005:
            continue

        sb = SafeBox.get_gold_safe_by_karat(karat)
        if not sb:
            raise Exception(f'لا توجد خزينة ذهب نشطة لعيار {karat}')

        tx = SafeBoxTransaction(
            safe_box_id=sb.id,
            ref_type='invoice_gold',
            ref_id=invoice.id,
            invoice_id=invoice.id,
            payment_method_id=None,
            direction=direction,
            amount_cash=0.0,
            notes=f"Invoice {invoice_number} - {getattr(invoice, 'invoice_type', '')}",
            created_by=created_by,
        )

        grams = float(grams)
        if karat == 18:
            tx.weight_18k = grams
        elif karat == 22:
            tx.weight_22k = grams
        elif karat == 24:
            tx.weight_24k = grams
        else:
            tx.weight_21k = grams

        db.session.add(tx)
        created.append(tx)

    return created


def _append_safe_reversal_transactions_for_invoice_gold(invoice: Invoice, created_by: str = None, reason: str = None):
    """Append reversing SafeBoxTransaction rows for a previously-posted invoice gold movement."""
    if not invoice or not getattr(invoice, 'id', None):
        return []

    existing_reversal = (
        SafeBoxTransaction.query.filter_by(ref_type='invoice_gold_reversal', ref_id=invoice.id)
        .order_by(SafeBoxTransaction.id.desc())
        .first()
    )
    if existing_reversal:
        return []

    original = SafeBoxTransaction.query.filter_by(ref_type='invoice_gold', ref_id=invoice.id).all()
    if not original:
        return []

    invoice_number = getattr(invoice, 'invoice_number', None) or str(getattr(invoice, 'id', ''))
    created = []
    for tx in original:
        rev = SafeBoxTransaction(
            safe_box_id=tx.safe_box_id,
            ref_type='invoice_gold_reversal',
            ref_id=invoice.id,
            invoice_id=invoice.id,
            payment_method_id=None,
            direction='out' if (tx.direction or 'in') == 'in' else 'in',
            amount_cash=0.0,
            weight_18k=float(tx.weight_18k or 0.0),
            weight_21k=float(tx.weight_21k or 0.0),
            weight_22k=float(tx.weight_22k or 0.0),
            weight_24k=float(tx.weight_24k or 0.0),
            notes=(reason or '') or f"Reversal for invoice {invoice_number}",
            created_by=created_by,
        )
        db.session.add(rev)
        created.append(rev)
    return created

def _get_shift_window_for_user(user_name: str):
    """Determine the current shift window.

    Simplest rule:
    - From: last successful shift closing timestamp for this user (if any)
      otherwise start of today.
    - To: now.

    Note: timestamps are stored as naive UTC in AuditLog by default.
    This implementation uses naive datetimes consistently.
    """
    now = datetime.now()
    today_start = datetime.combine(now.date(), datetime.min.time())

    try:
        last_close = (
            AuditLog.query.filter_by(action='shift_closing', success=True)
            .filter(AuditLog.user_name == user_name)
            .order_by(AuditLog.timestamp.desc())
            .first()
        )
        if last_close and last_close.timestamp:
            return last_close.timestamp, now
    except Exception:
        pass

    return today_start, now


@posting_bp.route('/shift-closing/summary', methods=['GET'])
@require_permission('safe_boxes.view')
def get_shift_closing_summary():
    """Return expected amounts per payment method for the current shift."""
    try:
        user_name = None
        try:
            user_name = getattr(getattr(g, 'current_user', None), 'username', None)
        except Exception:
            user_name = None
        user_name = user_name or 'system'

        # Allow overriding window.
        from_q = request.args.get('from')
        to_q = request.args.get('to')
        if from_q or to_q:
            try:
                window_from = datetime.fromisoformat(from_q) if from_q else None
            except Exception:
                return jsonify({'success': False, 'message': 'invalid_from'}), 400
            try:
                window_to = datetime.fromisoformat(to_q) if to_q else None
            except Exception:
                return jsonify({'success': False, 'message': 'invalid_to'}), 400
            if window_from is None or window_to is None:
                # If one side is missing, fill from defaults.
                default_from, default_to = _get_shift_window_for_user(user_name)
                window_from = window_from or default_from
                window_to = window_to or default_to
        else:
            window_from, window_to = _get_shift_window_for_user(user_name)

        pms = (
            PaymentMethod.query.filter_by(is_active=True)
            .order_by(PaymentMethod.display_order.asc(), PaymentMethod.id.asc())
            .all()
        )

        # Payment type categories (cash/card/bnpl/...) - best-effort
        pm_codes = list({(pm.payment_type or '').strip() for pm in pms if (pm.payment_type or '').strip()})
        code_to_category = {}
        if pm_codes:
            try:
                for pt in PaymentType.query.filter(PaymentType.code.in_(pm_codes)).all():
                    code_to_category[(pt.code or '').strip()] = (pt.category or '').strip() or None
            except Exception:
                code_to_category = {}

        # Preload safe box names
        safe_box_ids = [pm.default_safe_box_id for pm in pms if getattr(pm, 'default_safe_box_id', None)]
        safe_boxes = {}
        if safe_box_ids:
            for sb in SafeBox.query.filter(SafeBox.id.in_(safe_box_ids)).all():
                safe_boxes[sb.id] = sb

        rows = []
        for pm in pms:
            code = (pm.payment_type or '').strip()
            category = code_to_category.get(code)
            signed_sum = (
                db.session.query(
                    func.coalesce(
                        func.sum(
                            case(
                                (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.amount_cash),
                                else_=-SafeBoxTransaction.amount_cash,
                            )
                        ),
                        0.0,
                    )
                )
                .filter(
                    or_(
                        SafeBoxTransaction.payment_method_id == pm.id,
                        and_(
                            SafeBoxTransaction.payment_method_id.is_(None),
                            SafeBoxTransaction.safe_box_id == pm.default_safe_box_id,
                        ),
                    )
                )
                .filter(or_(SafeBoxTransaction.ref_type.is_(None), SafeBoxTransaction.ref_type != 'shift_closing_settlement'))
                .filter(SafeBoxTransaction.created_at >= window_from)
                .filter(SafeBoxTransaction.created_at <= window_to)
                .scalar()
            )

            expected_amount = float(signed_sum or 0.0)
            sb_id = getattr(pm, 'default_safe_box_id', None)
            sb = safe_boxes.get(sb_id) if sb_id else None

            # Fallback category via safe type when PaymentType is missing
            safe_type = getattr(sb, 'safe_type', None) if sb else None
            if not category and safe_type == 'cash':
                category = 'cash'

            is_cash = (category == 'cash') or (safe_type == 'cash')

            rows.append({
                'payment_method_id': pm.id,
                'payment_method_name': pm.name,
                'payment_type': code,
                'category': category,
                'is_cash': bool(is_cash),
                'default_safe_box_id': sb_id,
                'safe_box_name': getattr(sb, 'name', None) if sb else None,
                'expected_amount': round(expected_amount, 2),
            })

        return jsonify({
            'success': True,
            'from': window_from.isoformat(),
            'to': window_to.isoformat(),
            'rows': rows,
        }), 200

    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/shift-closing/summary-gold', methods=['GET'])
@require_permission('safe_boxes.view')
def get_shift_closing_gold_summary():
    """Return expected gold weights (18/21/22/24) for the current shift.

    Source of truth: SafeBoxTransaction weight fields for gold safes.
    """
    try:
        user_name = None
        try:
            user_name = getattr(getattr(g, 'current_user', None), 'username', None)
        except Exception:
            user_name = None
        user_name = user_name or 'system'

        # Allow overriding window.
        from_q = request.args.get('from')
        to_q = request.args.get('to')
        if from_q or to_q:
            try:
                window_from = datetime.fromisoformat(from_q) if from_q else None
            except Exception:
                return jsonify({'success': False, 'message': 'invalid_from'}), 400
            try:
                window_to = datetime.fromisoformat(to_q) if to_q else None
            except Exception:
                return jsonify({'success': False, 'message': 'invalid_to'}), 400
            if window_from is None or window_to is None:
                default_from, default_to = _get_shift_window_for_user(user_name)
                window_from = window_from or default_from
                window_to = window_to or default_to
        else:
            window_from, window_to = _get_shift_window_for_user(user_name)

        gold_safe_ids = [
            sb.id
            for sb in SafeBox.query.filter_by(is_active=True, safe_type='gold').all()
            if sb and sb.id
        ]

        if not gold_safe_ids:
            return jsonify({
                'success': True,
                'from': window_from.isoformat(),
                'to': window_to.isoformat(),
                'totals': {
                    '18k': 0.0,
                    '21k': 0.0,
                    '22k': 0.0,
                    '24k': 0.0,
                },
            }), 200

        totals_row = (
            db.session.query(
                func.coalesce(
                    func.sum(
                        case(
                            (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_18k),
                            else_=-SafeBoxTransaction.weight_18k,
                        )
                    ),
                    0.0,
                ).label('w18'),
                func.coalesce(
                    func.sum(
                        case(
                            (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_21k),
                            else_=-SafeBoxTransaction.weight_21k,
                        )
                    ),
                    0.0,
                ).label('w21'),
                func.coalesce(
                    func.sum(
                        case(
                            (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_22k),
                            else_=-SafeBoxTransaction.weight_22k,
                        )
                    ),
                    0.0,
                ).label('w22'),
                func.coalesce(
                    func.sum(
                        case(
                            (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_24k),
                            else_=-SafeBoxTransaction.weight_24k,
                        )
                    ),
                    0.0,
                ).label('w24'),
            )
            .filter(SafeBoxTransaction.safe_box_id.in_(gold_safe_ids))
            .filter(or_(SafeBoxTransaction.ref_type.is_(None), SafeBoxTransaction.ref_type != 'shift_closing_settlement'))
            .filter(SafeBoxTransaction.created_at >= window_from)
            .filter(SafeBoxTransaction.created_at <= window_to)
            .first()
        )

        w18 = float(getattr(totals_row, 'w18', 0.0) or 0.0)
        w21 = float(getattr(totals_row, 'w21', 0.0) or 0.0)
        w22 = float(getattr(totals_row, 'w22', 0.0) or 0.0)
        w24 = float(getattr(totals_row, 'w24', 0.0) or 0.0)

        return jsonify({
            'success': True,
            'from': window_from.isoformat(),
            'to': window_to.isoformat(),
            'totals': {
                '18k': round(w18, 3),
                '21k': round(w21, 3),
                '22k': round(w22, 3),
                '24k': round(w24, 3),
            },
        }), 200

    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/shift-closing/close', methods=['POST'])
@require_permission('safe_boxes.edit')
def close_shift():
    """Submit shift closing report and write it into AuditLog."""
    data = request.get_json(silent=True) or {}
    entries = data.get('entries')
    if not isinstance(entries, list) or len(entries) == 0:
        return jsonify({'success': False, 'message': 'entries_required'}), 400

    gold_actuals = data.get('gold_actuals')
    if gold_actuals is not None and not isinstance(gold_actuals, dict):
        return jsonify({'success': False, 'message': 'invalid_gold_actuals'}), 400

    user_name = None
    try:
        user_name = getattr(getattr(g, 'current_user', None), 'username', None)
    except Exception:
        user_name = None
    user_name = user_name or 'system'

    # Resolve window
    from_str = data.get('from')
    to_str = data.get('to')
    try:
        window_from = datetime.fromisoformat(from_str) if from_str else None
    except Exception:
        return jsonify({'success': False, 'message': 'invalid_from'}), 400
    try:
        window_to = datetime.fromisoformat(to_str) if to_str else None
    except Exception:
        return jsonify({'success': False, 'message': 'invalid_to'}), 400
    if window_from is None or window_to is None:
        default_from, default_to = _get_shift_window_for_user(user_name)
        window_from = window_from or default_from
        window_to = window_to or default_to

    def _to_float(v):
        try:
            if v in (None, '', False):
                return 0.0
            return float(v)
        except Exception:
            return 0.0

    settle_cash = bool(data.get('settle_cash') is True)
    opening_cash_amount = 0.0
    try:
        opening_cash_amount = float(data.get('opening_cash_amount') or 0.0)
    except Exception:
        opening_cash_amount = 0.0
    if opening_cash_amount < 0:
        opening_cash_amount = 0.0

    # Payment type categories (cash/card/bnpl/...) - best-effort
    try:
        pt_rows = PaymentType.query.filter_by(is_active=True).all()
        code_to_category = {(pt.code or '').strip(): (pt.category or '').strip() or None for pt in pt_rows}
    except Exception:
        code_to_category = {}

    # Validate payload and normalize amounts
    normalized = []
    for idx, row in enumerate(entries):
        if not isinstance(row, dict):
            return jsonify({'success': False, 'message': f'invalid_entry_{idx}'}), 400
        pm_id = row.get('payment_method_id')
        if pm_id in (None, '', False):
            return jsonify({'success': False, 'message': f'missing_payment_method_id_{idx}'}), 400
        try:
            pm_id = int(pm_id)
        except Exception:
            return jsonify({'success': False, 'message': f'invalid_payment_method_id_{idx}'}), 400

        expected = _to_float(row.get('expected_amount'))
        actual = _to_float(row.get('actual_amount'))

        denominations = row.get('denominations')
        denom_total = None
        if isinstance(denominations, dict) and len(denominations) > 0:
            try:
                total = 0.0
                for k, v in denominations.items():
                    denom = float(k)
                    count = int(v)
                    if denom <= 0 or count < 0:
                        continue
                    total += denom * count
                denom_total = round(total, 2)
                actual = float(denom_total)
            except Exception:
                denom_total = None
                denominations = None

        pm_obj = PaymentMethod.query.get(pm_id)
        pm_name = pm_obj.name if pm_obj else None
        pm_code = (pm_obj.payment_type or '').strip() if pm_obj else None
        category = code_to_category.get(pm_code or '') if pm_code else None
        default_sb_id = getattr(pm_obj, 'default_safe_box_id', None) if pm_obj else None
        sb = SafeBox.query.get(default_sb_id) if default_sb_id else None
        safe_type = getattr(sb, 'safe_type', None) if sb else None
        if not category and safe_type == 'cash':
            category = 'cash'
        is_cash = (category == 'cash') or (safe_type == 'cash')

        normalized.append({
            'payment_method_id': pm_id,
            'payment_method_name': pm_name,
            'payment_type': pm_code,
            'category': category,
            'is_cash': bool(is_cash),
            'default_safe_box_id': default_sb_id,
            'expected_amount': round(expected, 2),
            'actual_amount': round(actual, 2),
            'difference': round(actual - expected, 2),
            'denominations': denominations if isinstance(denominations, dict) else None,
            'denominations_total': denom_total,
        })

    # Create a human-readable reference
    entity_number = f"SHIFT-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

    total_expected = round(sum(float(r.get('expected_amount') or 0.0) for r in normalized), 2)
    total_actual = round(sum(float(r.get('actual_amount') or 0.0) for r in normalized), 2)
    total_difference = round(total_actual - total_expected, 2)

    details = {
        'from': window_from.isoformat(),
        'to': window_to.isoformat(),
        'totals': {
            'total_expected': total_expected,
            'total_actual': total_actual,
            'total_difference': total_difference,
        },
        'summary_ar': f"تم إغلاق الوردية بواسطة {user_name} بفرق {total_difference:.2f}",
        'entries': normalized,
        'notes': (data.get('notes') or '').strip() or None,
        'settle_cash': settle_cash,
        'opening_cash_amount': round(opening_cash_amount, 2),
    }

    # Optional: gold reconciliation snapshot (expected from ledger + provided actuals)
    gold_details = None
    try:
        if isinstance(gold_actuals, dict):
            # find active gold safes
            gold_safes = SafeBox.query.filter_by(safe_type='gold').all()
            gold_safe_ids = [sb.id for sb in gold_safes if getattr(sb, 'is_active', True)]

            expected_map = {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
            if gold_safe_ids:
                totals_row = (
                    db.session.query(
                        func.coalesce(
                            func.sum(
                                case(
                                    (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_18k),
                                    else_=-SafeBoxTransaction.weight_18k,
                                )
                            ),
                            0.0,
                        ).label('w18'),
                        func.coalesce(
                            func.sum(
                                case(
                                    (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_21k),
                                    else_=-SafeBoxTransaction.weight_21k,
                                )
                            ),
                            0.0,
                        ).label('w21'),
                        func.coalesce(
                            func.sum(
                                case(
                                    (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_22k),
                                    else_=-SafeBoxTransaction.weight_22k,
                                )
                            ),
                            0.0,
                        ).label('w22'),
                        func.coalesce(
                            func.sum(
                                case(
                                    (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.weight_24k),
                                    else_=-SafeBoxTransaction.weight_24k,
                                )
                            ),
                            0.0,
                        ).label('w24'),
                    )
                    .filter(SafeBoxTransaction.safe_box_id.in_(gold_safe_ids))
                    .filter(or_(SafeBoxTransaction.ref_type.is_(None), SafeBoxTransaction.ref_type != 'shift_closing_settlement'))
                    .filter(SafeBoxTransaction.created_at >= window_from)
                    .filter(SafeBoxTransaction.created_at <= window_to)
                    .first()
                )

                expected_map = {
                    '18k': float(getattr(totals_row, 'w18', 0.0) or 0.0),
                    '21k': float(getattr(totals_row, 'w21', 0.0) or 0.0),
                    '22k': float(getattr(totals_row, 'w22', 0.0) or 0.0),
                    '24k': float(getattr(totals_row, 'w24', 0.0) or 0.0),
                }

            actual_map = {
                '18k': _to_float(gold_actuals.get('18k')),
                '21k': _to_float(gold_actuals.get('21k')),
                '22k': _to_float(gold_actuals.get('22k')),
                '24k': _to_float(gold_actuals.get('24k')),
            }
            diff_map = {k: float(actual_map.get(k, 0.0)) - float(expected_map.get(k, 0.0)) for k in expected_map.keys()}

            def _to_pure_24(m: dict) -> float:
                w18 = float(m.get('18k', 0.0) or 0.0)
                w21 = float(m.get('21k', 0.0) or 0.0)
                w22 = float(m.get('22k', 0.0) or 0.0)
                w24 = float(m.get('24k', 0.0) or 0.0)
                return (w18 * (18.0 / 24.0)) + (w21 * (21.0 / 24.0)) + (w22 * (22.0 / 24.0)) + (w24 * 1.0)

            pure_expected = _to_pure_24(expected_map)
            pure_actual = _to_pure_24(actual_map)
            pure_diff = pure_actual - pure_expected

            gold_details = {
                'expected': {k: round(float(v or 0.0), 3) for k, v in expected_map.items()},
                'actual': {k: round(float(v or 0.0), 3) for k, v in actual_map.items()},
                'difference': {k: round(float(v or 0.0), 3) for k, v in diff_map.items()},
                'pure_24k': {
                    'expected': round(float(pure_expected or 0.0), 3),
                    'actual': round(float(pure_actual or 0.0), 3),
                    'difference': round(float(pure_diff or 0.0), 3),
                },
                'summary_ar': (
                    f"مطابقة الذهب - 18: {diff_map['18k']:+.3f} جم، "
                    f"21: {diff_map['21k']:+.3f} جم، "
                    f"22: {diff_map['22k']:+.3f} جم، "
                    f"24: {diff_map['24k']:+.3f} جم"
                ),
            }

            details['gold'] = gold_details
    except Exception:
        # keep shift closing best-effort even if gold snapshot fails
        pass

    try:
        log = AuditLog.log_action(
            user_name=user_name,
            action='shift_closing',
            entity_type='ShiftClosing',
            entity_id=0,
            entity_number=entity_number,
            details=json.dumps(details, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent'),
            success=True,
        )
        db.session.flush()
        if log:
            try:
                log.entity_id = log.id
            except Exception:
                pass

        # Optional settlement (ledger-only) to reflect physically clearing cash drawers.
        settlement_rows = []
        if settle_cash:
            for entry in normalized:
                if not entry.get('is_cash'):
                    continue
                sb_id = entry.get('default_safe_box_id')
                if not sb_id:
                    continue

                actual_amt = float(entry.get('actual_amount') or 0.0)
                withdraw_amt = max(round(actual_amt - opening_cash_amount, 2), 0.0)
                if withdraw_amt <= 0:
                    continue

                tx = SafeBoxTransaction(
                    safe_box_id=int(sb_id),
                    ref_type='shift_closing_settlement',
                    ref_id=(log.id if log else None),
                    payment_method_id=int(entry.get('payment_method_id')),
                    direction='out',
                    amount_cash=float(withdraw_amt),
                    notes=f"Shift closing settlement {entity_number}",
                    created_by=user_name,
                )
                db.session.add(tx)
                settlement_rows.append({
                    'safe_box_id': int(sb_id),
                    'payment_method_id': int(entry.get('payment_method_id')),
                    'amount_cash': float(withdraw_amt),
                    'direction': 'out',
                })

        if settlement_rows:
            try:
                details['settlement'] = settlement_rows
                if log:
                    log.details = json.dumps(details, ensure_ascii=False)
            except Exception:
                pass

        # --- Security thresholds: create critical in-app alert when deficit exceeds threshold ---
        try:
            settings_row = Settings.query.first()
            config = {}
            if settings_row and settings_row.weight_closing_settings:
                try:
                    decoded = json.loads(settings_row.weight_closing_settings)
                    if isinstance(decoded, dict):
                        config = decoded
                except Exception:
                    config = {}

            cash_threshold = 50.0
            gold_threshold = 0.10
            try:
                cash_threshold = float(config.get('shift_close_cash_deficit_threshold', cash_threshold) or cash_threshold)
            except Exception:
                cash_threshold = 50.0
            try:
                gold_threshold = float(
                    config.get('shift_close_gold_pure_deficit_threshold_grams', gold_threshold) or gold_threshold
                )
            except Exception:
                gold_threshold = 0.10

            cash_deficit = abs(float(total_difference or 0.0))

            pure_gold_diff = None
            try:
                pure_gold_diff = float((((details.get('gold') or {}).get('pure_24k') or {}).get('difference')))
            except Exception:
                pure_gold_diff = None

            gold_deficit = abs(float(pure_gold_diff or 0.0)) if pure_gold_diff is not None else 0.0

            is_cash_critical = cash_deficit > cash_threshold if cash_threshold is not None else False
            is_gold_critical = (pure_gold_diff is not None) and (gold_deficit > gold_threshold)

            if is_cash_critical or is_gold_critical:
                title = 'تنبيه عهده - إغلاق وردية'
                message = (
                    f"تم رصد فرق يتجاوز العتبة عند إغلاق {entity_number}. "
                    f"فرق النقد: {total_difference:+.2f}، "
                    f"فرق الذهب الصافي: {(pure_gold_diff if pure_gold_diff is not None else 0.0):+.3f} جم"
                )

                alert_details = {
                    'shift': {
                        'entity_number': entity_number,
                        'from': details.get('from'),
                        'to': details.get('to'),
                    },
                    'diffs': {
                        'cash_difference': float(total_difference or 0.0),
                        'gold_pure_24k_difference': float(pure_gold_diff) if pure_gold_diff is not None else None,
                    },
                    'thresholds': {
                        'cash_deficit_threshold': float(cash_threshold),
                        'gold_pure_deficit_threshold_grams': float(gold_threshold),
                    },
                    'flags': {
                        'cash_critical': bool(is_cash_critical),
                        'gold_critical': bool(is_gold_critical),
                    },
                    'audit_log_id': (log.id if log else None),
                }

                db.session.add(
                    SystemAlert(
                        alert_type='shift_closing',
                        severity='critical',
                        title=title,
                        message=message,
                        entity_type='ShiftClosing',
                        entity_id=(log.id if log else None),
                        entity_number=entity_number,
                        details=json.dumps(alert_details, ensure_ascii=False),
                        created_by=user_name,
                    )
                )
        except Exception:
            # alerts must never break shift closing
            pass

        db.session.commit()
        return jsonify({
            'success': True,
            'entity_number': entity_number,
            'totals': details.get('totals'),
        }), 201
    except Exception as e:
        db.session.rollback()
        # best-effort failure log
        try:
            AuditLog.log_action(
                user_name=user_name,
                action='shift_closing',
                entity_type='ShiftClosing',
                entity_id=0,
                entity_number=entity_number,
                details=json.dumps(details, ensure_ascii=False),
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=False,
                error_message=str(e),
            )
            db.session.commit()
        except Exception:
            db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500

# ==========================================
# 📋 عرض الفواتير/القيود حسب حالة الترحيل
# ==========================================

@posting_bp.route('/invoices/unposted', methods=['GET'])
@require_permission('invoice.view')
def get_unposted_invoices():
    """عرض جميع الفواتير غير المرحلة"""
    try:
        invoices = Invoice.query.filter_by(is_posted=False).order_by(Invoice.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(invoices),
            'invoices': [inv.to_dict() for inv in invoices]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/invoices/posted', methods=['GET'])
@require_permission('invoice.view')
def get_posted_invoices():
    """عرض جميع الفواتير المرحلة"""
    try:
        invoices = Invoice.query.filter_by(is_posted=True).order_by(Invoice.posted_at.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(invoices),
            'invoices': [inv.to_dict() for inv in invoices]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/unposted', methods=['GET'])
@require_permission('journal.view')
def get_unposted_entries():
    """عرض جميع القيود غير المرحلة"""
    try:
        entries = JournalEntry.query.filter_by(
            is_posted=False, 
            is_deleted=False
        ).order_by(JournalEntry.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(entries),
            'entries': [entry.to_dict() for entry in entries]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/posted', methods=['GET'])
@require_permission('journal.view')
def get_posted_entries():
    """عرض جميع القيود المرحلة"""
    try:
        entries = JournalEntry.query.filter_by(
            is_posted=True,
            is_deleted=False
        ).order_by(JournalEntry.posted_at.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(entries),
            'entries': [entry.to_dict() for entry in entries]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# ✅ ترحيل الفواتير
# ==========================================

@posting_bp.route('/invoices/post/<int:invoice_id>', methods=['POST'])
@require_permission('invoice.post')
def post_invoice(invoice_id):
    """
    ترحيل فاتورة واحدة
    
    Body:
    {
        "posted_by": "اسم المستخدم"
    }
    
    يتطلب صلاحية: invoice.post
    """
    try:
        # استخدام اسم المستخدم المصادق عليه
        posted_by = g.current_user.username
        
        invoice = Invoice.query.get(invoice_id)
        if not invoice:
            return jsonify({'success': False, 'message': 'الفاتورة غير موجودة'}), 404
        
        if invoice.is_posted:
            return jsonify({
                'success': False, 
                'message': 'الفاتورة مرحلة بالفعل'
            }), 400
        
        # ترحيل الفاتورة
        invoice.is_posted = True
        invoice.posted_at = datetime.now()
        invoice.posted_by = posted_by

        # Append gold inventory movements into SafeBox ledger (append-only)
        _append_safe_transactions_for_invoice_gold(invoice, created_by=posted_by)
        
        db.session.commit()
        
        # 📋 تسجيل في Audit Log
        try:
            details = json.dumps({
                'invoice_type': invoice.invoice_type,
                'total': float(invoice.total) if invoice.total else 0,
                'date': str(invoice.date),
                'customer_id': invoice.customer_id if hasattr(invoice, 'customer_id') else None,
            }, ensure_ascii=False)
            
            AuditLog.log_action(
                user_name=posted_by,
                action='post_invoice',
                entity_type='Invoice',
                entity_id=invoice_id,
                entity_number=getattr(invoice, 'invoice_number', None),
                details=details,
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=True
            )
        except Exception as log_error:
            print(f"خطأ في تسجيل Audit Log: {log_error}")
        
        return jsonify({
            'success': True,
            'message': 'تم ترحيل الفاتورة بنجاح',
            'invoice': invoice.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        
        # 📋 تسجيل الفشل في Audit Log
        try:
            posted_by = g.current_user.username if hasattr(g, 'current_user') else 'النظام'
            AuditLog.log_action(
                user_name=posted_by,
                action='post_invoice',
                entity_type='Invoice',
                entity_id=invoice_id,
                entity_number=None,
                details=None,
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=False,
                error_message=str(e)
            )
        except:
            pass
        
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/invoices/post-batch', methods=['POST'])
@require_permission('invoice.post')
def post_invoices_batch():
    """
    ترحيل مجموعة فواتير
    
    Body:
    {
        "invoice_ids": [1, 2, 3, ...]
    }
    
    يتطلب صلاحية: invoice.post
    """
    try:
        posted_by = g.current_user.username
        data = request.get_json()
        invoice_ids = data.get('invoice_ids', [])
        
        if not invoice_ids:
            return jsonify({'success': False, 'message': 'لم يتم تحديد أي فواتير'}), 400
        
        invoices = Invoice.query.filter(Invoice.id.in_(invoice_ids)).all()
        
        posted_count = 0
        skipped_count = 0
        
        for invoice in invoices:
            if not invoice.is_posted:
                invoice.is_posted = True
                invoice.posted_at = datetime.now()
                invoice.posted_by = posted_by
                posted_count += 1

                # Append gold inventory movements into SafeBox ledger (append-only)
                _append_safe_transactions_for_invoice_gold(invoice, created_by=posted_by)
                
                # تسجيل كل عملية ناجحة
                AuditLog.log_action(
                    user_name=posted_by,
                    action='post',
                    entity_type='invoice',
                    entity_id=invoice.id,
                    entity_number=invoice.invoice_number,
                    details=json.dumps({'batch_operation': True}, ensure_ascii=False),
                    ip_address=request.remote_addr,
                    user_agent=request.headers.get('User-Agent')
                )
            else:
                skipped_count += 1
        
        db.session.commit()
        
        # تسجيل العملية الجماعية
        AuditLog.log_action(
            user_name=posted_by,
            action='post_batch',
            entity_type='invoice',
            entity_id=0,  # batch operation
            details=json.dumps({
                'total_invoices': len(invoice_ids),
                'posted_count': posted_count,
                'skipped_count': skipped_count
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        return jsonify({
            'success': True,
            'message': f'تم ترحيل {posted_count} فاتورة، تم تخطي {skipped_count}',
            'posted_count': posted_count,
            'skipped_count': skipped_count
        }), 200
        
    except Exception as e:
        db.session.rollback()
        posted_by = g.current_user.username if hasattr(g, 'current_user') else 'النظام'
        AuditLog.log_action(
            user_name=posted_by,
            action='post_batch',
            entity_type='invoice',
            entity_id=0,  # batch operation لا يوجد entity_id محدد
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/invoices/unpost/<int:invoice_id>', methods=['POST'])
@require_permission('invoice.unpost')
def unpost_invoice(invoice_id):
    """
    إلغاء ترحيل فاتورة
    
    يتطلب صلاحية: invoice.unpost
    
    ⚠️ تحذير: هذا الإجراء حساس ويجب استخدامه بحذر
    """
    try:
        posted_by = g.current_user.username
        invoice = Invoice.query.get(invoice_id)
        if not invoice:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='invoice',
                entity_id=invoice_id,
                success=False,
                error_message='الفاتورة غير موجودة',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({'success': False, 'message': 'الفاتورة غير موجودة'}), 404
        
        if not invoice.is_posted:
            AuditLog.log_action(
                user_name=request.json.get('posted_by', 'system'),
                action='unpost',
                entity_type='invoice',
                entity_id=invoice_id,
                entity_number=invoice.invoice_number,
                success=False,
                error_message='الفاتورة غير مرحلة أصلاً',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({
                'success': False, 
                'message': 'الفاتورة غير مرحلة أصلاً'
            }), 400
        
        # Append reversal ledger movements (append-only)
        _append_safe_reversal_transactions_for_invoice_gold(
            invoice,
            created_by=posted_by,
            reason=f"Unpost invoice {getattr(invoice, 'invoice_number', None) or invoice.id}",
        )

        # إلغاء الترحيل
        invoice.is_posted = False
        invoice.posted_at = None
        invoice.posted_by = None
        
        # تسجيل العملية الناجحة
        posted_by = g.current_user.username if hasattr(g, 'current_user') else 'system'
        AuditLog.log_action(
            user_name=posted_by,
            action='unpost',
            entity_type='invoice',
            entity_id=invoice_id,
            entity_number=invoice.invoice_number,
            details=json.dumps({
                'invoice_type': invoice.invoice_type,
                'total': float(invoice.total or 0)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()  # Commit بعد تسجيل الـ Audit Log
        
        return jsonify({
            'success': True,
            'message': 'تم إلغاء ترحيل الفاتورة',
            'invoice': invoice.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=request.json.get('posted_by', 'system'),
            action='unpost',
            entity_type='invoice',
            entity_id=invoice_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# ✅ ترحيل القيود
# ==========================================

@posting_bp.route('/journal-entries/post/<int:entry_id>', methods=['POST'])
@require_permission('journal.post')
def post_journal_entry(entry_id):
    """
    ترحيل قيد يومية
    
    يتطلب صلاحية: journal.post
    """
    try:
        posted_by = g.current_user.username
        
        entry = JournalEntry.query.get(entry_id)
        if not entry:
            return jsonify({'success': False, 'message': 'القيد غير موجود'}), 404
        
        if entry.is_deleted:
            return jsonify({'success': False, 'message': 'القيد محذوف'}), 400
        
        if entry.is_posted:
            return jsonify({
                'success': False, 
                'message': 'القيد مرحل بالفعل'
            }), 400
        
        # التحقق من التوازن قبل الترحيل (النظام يستخدم cash_debit/credit و karat debits/credits)
        total_cash_debit = sum(line.cash_debit or 0 for line in entry.lines if not line.is_deleted)
        total_cash_credit = sum(line.cash_credit or 0 for line in entry.lines if not line.is_deleted)
        
        # التحقق من توازن النقد
        if abs(total_cash_debit - total_cash_credit) > 0.01:  # هامش خطأ صغير
            return jsonify({
                'success': False,
                'message': f'القيد غير متوازن (نقد). مدين: {total_cash_debit}, دائن: {total_cash_credit}'
            }), 400
        
        # التحقق من توازن الذهب لكل عيار
        for karat in ['18k', '21k', '22k', '24k']:
            total_debit = sum(getattr(line, f'debit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
            total_credit = sum(getattr(line, f'credit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
            
            if abs(total_debit - total_credit) > 0.001:  # هامش خطأ أصغر للذهب
                return jsonify({
                    'success': False,
                    'message': f'القيد غير متوازن (عيار {karat}). مدين: {total_debit}, دائن: {total_credit}'
                }), 400
        
        # ترحيل القيد
        entry.is_posted = True
        entry.posted_at = datetime.now()
        entry.posted_by = posted_by
        
        # تسجيل العملية الناجحة
        AuditLog.log_action(
            user_name=posted_by,
            action='post',
            entity_type='journal_entry',
            entity_id=entry_id,
            entity_number=entry.entry_number,
            details=json.dumps({
                'entry_type': entry.entry_type,
                'description': entry.description,
                'total_cash_debit': float(total_cash_debit),
                'total_cash_credit': float(total_cash_credit)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()  # Commit بعد تسجيل الـ Audit Log
        
        return jsonify({
            'success': True,
            'message': 'تم ترحيل القيد بنجاح',
            'entry': entry.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='post',
            entity_type='journal_entry',
            entity_id=entry_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/post-batch', methods=['POST'])
@require_permission('journal.post')
def post_journal_entries_batch():
    """
    ترحيل مجموعة قيود
    
    Body:
    {
        "entry_ids": [1, 2, 3, ...]
    }
    
    يتطلب صلاحية: journal.post
    """
    try:
        posted_by = g.current_user.username
        data = request.get_json()
        entry_ids = data.get('entry_ids', [])
        
        if not entry_ids:
            return jsonify({'success': False, 'message': 'لم يتم تحديد أي قيود'}), 400
        
        entries = JournalEntry.query.filter(
            JournalEntry.id.in_(entry_ids),
            JournalEntry.is_deleted == False
        ).all()
        
        posted_count = 0
        skipped_count = 0
        errors = []
        
        for entry in entries:
            if not entry.is_posted:
                # التحقق من التوازن (النقد)
                total_cash_debit = sum(line.cash_debit or 0 for line in entry.lines if not line.is_deleted)
                total_cash_credit = sum(line.cash_credit or 0 for line in entry.lines if not line.is_deleted)
                
                if abs(total_cash_debit - total_cash_credit) > 0.01:
                    errors.append(f"القيد {entry.entry_number} غير متوازن (نقد)")
                    skipped_count += 1
                    continue
                
                # التحقق من توازن الذهب
                is_balanced = True
                for karat in ['18k', '21k', '22k', '24k']:
                    total_debit = sum(getattr(line, f'debit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
                    total_credit = sum(getattr(line, f'credit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
                    
                    if abs(total_debit - total_credit) > 0.001:
                        errors.append(f"القيد {entry.entry_number} غير متوازن (عيار {karat})")
                        skipped_count += 1
                        is_balanced = False
                        break
                
                if not is_balanced:
                    continue
                
                entry.is_posted = True
                entry.posted_at = datetime.now()
                entry.posted_by = posted_by
                posted_count += 1
                
                # تسجيل كل عملية ناجحة
                AuditLog.log_action(
                    user_name=posted_by,
                    action='post',
                    entity_type='journal_entry',
                    entity_id=entry.id,
                    entity_number=entry.entry_number,
                    details=json.dumps({'batch_operation': True}, ensure_ascii=False),
                    ip_address=request.remote_addr,
                    user_agent=request.headers.get('User-Agent')
                )
            else:
                skipped_count += 1
        
        db.session.commit()
        
        # تسجيل العملية الجماعية
        AuditLog.log_action(
            user_name=posted_by,
            action='post_batch',
            entity_type='journal_entry',
            entity_id=0,  # batch operation
            details=json.dumps({
                'total_entries': len(entry_ids),
                'posted_count': posted_count,
                'skipped_count': skipped_count,
                'errors': errors
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        return jsonify({
            'success': True,
            'message': f'تم ترحيل {posted_count} قيد، تم تخطي {skipped_count}',
            'posted_count': posted_count,
            'skipped_count': skipped_count,
            'errors': errors
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/unpost/<int:entry_id>', methods=['POST'])
@require_permission('journal.unpost')
def unpost_journal_entry(entry_id):
    """
    إلغاء ترحيل قيد
    
    يتطلب صلاحية: journal.unpost
    ⚠️ تحذير: هذا الإجراء حساس ويجب استخدامه بحذر
    """
    try:
        posted_by = g.current_user.username
        entry = JournalEntry.query.get(entry_id)
        
        if not entry:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='journal_entry',
                entity_id=entry_id,
                success=False,
                error_message='القيد غير موجود',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({'success': False, 'message': 'القيد غير موجود'}), 404
        
        if entry.is_deleted:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='journal_entry',
                entity_id=entry_id,
                entity_number=entry.entry_number,
                success=False,
                error_message='القيد محذوف',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({'success': False, 'message': 'القيد محذوف'}), 400
        
        if not entry.is_posted:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='journal_entry',
                entity_id=entry_id,
                entity_number=entry.entry_number,
                success=False,
                error_message='القيد غير مرحل أصلاً',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({
                'success': False, 
                'message': 'القيد غير مرحل أصلاً'
            }), 400
        
        # إلغاء الترحيل
        entry.is_posted = False
        entry.posted_at = None
        entry.posted_by = None
        
        # تسجيل العملية الناجحة
        AuditLog.log_action(
            user_name=posted_by,
            action='unpost',
            entity_type='journal_entry',
            entity_id=entry_id,
            entity_number=entry.entry_number,
            details=json.dumps({
                'entry_type': entry.entry_type,
                'description': entry.description
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()  # Commit بعد تسجيل الـ Audit Log
        
        return jsonify({
            'success': True,
            'message': 'تم إلغاء ترحيل القيد',
            'entry': entry.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        posted_by = request.json.get('posted_by', 'system') if request.json else 'system'
        AuditLog.log_action(
            user_name=posted_by,
            action='unpost',
            entity_type='journal_entry',
            entity_id=entry_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# 📊 إحصائيات الترحيل
# ==========================================

@posting_bp.route('/posting/stats', methods=['GET'])
@optional_auth
def get_posting_stats():
    """عرض إحصائيات الترحيل (لا يتطلب صلاحيات)"""
    try:
        stats = {
            'invoices': {
                'total': Invoice.query.count(),
                'posted': Invoice.query.filter_by(is_posted=True).count(),
                'unposted': Invoice.query.filter_by(is_posted=False).count()
            },
            'journal_entries': {
                'total': JournalEntry.query.filter_by(is_deleted=False).count(),
                'posted': JournalEntry.query.filter_by(is_posted=True, is_deleted=False).count(),
                'unposted': JournalEntry.query.filter_by(is_posted=False, is_deleted=False).count()
            }
        }
        
        return jsonify({
            'success': True,
            'stats': stats
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# 📋 سجل التدقيق (Audit Log)
# ==========================================

@posting_bp.route('/audit-logs', methods=['GET'])
@require_permission('audit.view')
def get_audit_logs():
    """
    عرض سجلات التدقيق
    
    يتطلب صلاحية: audit.view
    
    Query Parameters:
    - limit: عدد السجلات (افتراضي 100)
    - user_name: تصفية حسب اسم المستخدم
    - action: تصفية حسب نوع العملية
    - entity_type: تصفية حسب نوع الكيان
    - entity_id: تصفية حسب معرف الكيان
    - success: تصفية حسب النجاح/الفشل (true/false)
    - from_date: من تاريخ (ISO format)
    - to_date: إلى تاريخ (ISO format)
    """
    try:
        # البارامترات
        limit = request.args.get('limit', 100, type=int)
        user_name = request.args.get('user_name')
        action = request.args.get('action')
        entity_type = request.args.get('entity_type')
        entity_id = request.args.get('entity_id', type=int)
        success = request.args.get('success')
        from_date = request.args.get('from_date')
        to_date = request.args.get('to_date')
        
        # بناء الاستعلام
        query = AuditLog.query
        
        if user_name:
            query = query.filter(AuditLog.user_name.like(f'%{user_name}%'))
        
        if action:
            query = query.filter_by(action=action)
        
        if entity_type:
            query = query.filter_by(entity_type=entity_type)
        
        if entity_id:
            query = query.filter_by(entity_id=entity_id)
        
        if success is not None:
            success_bool = success.lower() == 'true'
            query = query.filter_by(success=success_bool)
        
        if from_date:
            try:
                from_dt = datetime.fromisoformat(from_date)
                query = query.filter(AuditLog.timestamp >= from_dt)
            except:
                pass
        
        if to_date:
            try:
                to_dt = datetime.fromisoformat(to_date)
                query = query.filter(AuditLog.timestamp <= to_dt)
            except:
                pass
        
        # الترتيب والحد الأقصى
        logs = query.order_by(AuditLog.timestamp.desc()).limit(limit).all()
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/<int:log_id>', methods=['GET'])
@require_permission('audit.view')
def get_audit_log_detail(log_id):
    """الحصول على تفاصيل سجل تدقيق معين"""
    try:
        log = AuditLog.query.get(log_id)
        if not log:
            return jsonify({'success': False, 'message': 'السجل غير موجود'}), 404
        
        return jsonify({
            'success': True,
            'log': log.to_dict(include_details=True)
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/entity/<entity_type>/<int:entity_id>', methods=['GET'])
@require_permission('audit.view')
def get_audit_logs_by_entity(entity_type, entity_id):
    """الحصول على جميع سجلات التدقيق لكيان معين"""
    try:
        logs = AuditLog.get_logs_by_entity(entity_type, entity_id)
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'entity_type': entity_type,
            'entity_id': entity_id,
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/user/<user_name>', methods=['GET'])
@require_permission('audit.view')
def get_audit_logs_by_user(user_name):
    """الحصول على سجلات مستخدم معين"""
    try:
        limit = request.args.get('limit', 100, type=int)
        logs = AuditLog.get_logs_by_user(user_name, limit=limit)
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'user_name': user_name,
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/failed', methods=['GET'])
@require_permission('audit.view')
def get_failed_audit_logs():
    """الحصول على العمليات الفاشلة"""
    try:
        limit = request.args.get('limit', 50, type=int)
        logs = AuditLog.get_failed_logs(limit=limit)
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/stats', methods=['GET'])
@require_permission('audit.view')
def get_audit_stats():
    """إحصائيات سجل التدقيق"""
    try:
        from sqlalchemy import func
        
        # إجمالي السجلات
        total_logs = AuditLog.query.count()
        
        # السجلات الناجحة والفاشلة
        successful = AuditLog.query.filter_by(success=True).count()
        failed = AuditLog.query.filter_by(success=False).count()
        
        # أكثر العمليات تكراراً
        top_actions = db.session.query(
            AuditLog.action,
            func.count(AuditLog.id).label('count')
        ).group_by(AuditLog.action).order_by(func.count(AuditLog.id).desc()).limit(10).all()
        
        # أكثر المستخدمين نشاطاً
        top_users = db.session.query(
            AuditLog.user_name,
            func.count(AuditLog.id).label('count')
        ).group_by(AuditLog.user_name).order_by(func.count(AuditLog.id).desc()).limit(10).all()
        
        # السجلات اليوم
        today = datetime.now().date()
        today_start = datetime.combine(today, datetime.min.time())
        logs_today = AuditLog.query.filter(AuditLog.timestamp >= today_start).count()
        
        stats = {
            'total_logs': total_logs,
            'successful': successful,
            'failed': failed,
            'logs_today': logs_today,
            'top_actions': [{'action': action, 'count': count} for action, count in top_actions],
            'top_users': [{'user_name': user, 'count': count} for user, count in top_users]
        }
        
        return jsonify({
            'success': True,
            'stats': stats
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# 📝 نظام الموافقة على السندات (Voucher Approval)
# ==========================================

@posting_bp.route('/vouchers/pending', methods=['GET'])
@require_permission('voucher.view')
def get_pending_vouchers():
    """عرض جميع السندات بانتظار الموافقة"""
    try:
        from models import Voucher
        
        vouchers = Voucher.query.filter_by(
            status='pending'
        ).order_by(Voucher.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(vouchers),
            'vouchers': [v.to_dict() for v in vouchers]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/approved', methods=['GET'])
@require_permission('voucher.view')
def get_approved_vouchers():
    """عرض جميع السندات الموافق عليها"""
    try:
        from models import Voucher
        
        vouchers = Voucher.query.filter_by(
            status='approved'
        ).order_by(Voucher.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(vouchers),
            'vouchers': [v.to_dict() for v in vouchers]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/rejected', methods=['GET'])
@require_permission('voucher.view')
def get_rejected_vouchers():
    """عرض جميع السندات المرفوضة"""
    try:
        from models import Voucher
        
        vouchers = Voucher.query.filter_by(
            status='rejected'
        ).order_by(Voucher.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(vouchers),
            'vouchers': [v.to_dict() for v in vouchers]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/approve/<int:voucher_id>', methods=['POST'])
@require_permission('voucher.approve')
def approve_voucher(voucher_id):
    """
    الموافقة على سند
    
    يتطلب صلاحية: voucher.approve
    """
    try:
        from models import Voucher
        
        approved_by = g.current_user.username
        
        voucher = Voucher.query.get(voucher_id)
        if not voucher:
            return jsonify({'success': False, 'message': 'السند غير موجود'}), 404
        
        if voucher.status == 'approved':
            return jsonify({
                'success': False,
                'message': 'السند موافق عليه بالفعل'
            }), 400
        
        if voucher.status == 'cancelled':
            return jsonify({
                'success': False,
                'message': 'لا يمكن الموافقة على سند ملغى'
            }), 400
        
        # الموافقة على السند
        voucher.status = 'approved'
        voucher.approved_at = datetime.now()
        voucher.approved_by = approved_by
        
        # تسجيل العملية
        AuditLog.log_action(
            user_name=approved_by,
            action='voucher_approve',
            entity_type='voucher',
            entity_id=voucher_id,
            entity_number=voucher.voucher_number,
            details=json.dumps({
                'voucher_type': voucher.voucher_type,
                'amount_cash': float(voucher.amount_cash or 0),
                'amount_gold': float(voucher.amount_gold or 0),
                'description': voucher.description
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم الموافقة على السند بنجاح',
            'voucher': voucher.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='voucher_approve',
            entity_type='voucher',
            entity_id=voucher_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/reject/<int:voucher_id>', methods=['POST'])
@require_permission('voucher.approve')
def reject_voucher(voucher_id):
    """
    رفض سند
    
    يتطلب صلاحية: voucher.approve
    
    Body:
    {
        "rejection_reason": "سبب الرفض"
    }
    """
    try:
        from models import Voucher
        
        data = request.get_json()
        rejected_by = g.current_user.username
        rejection_reason = data.get('rejection_reason', '')
        
        if not rejection_reason:
            return jsonify({
                'success': False,
                'message': 'يجب تحديد سبب الرفض'
            }), 400
        
        voucher = Voucher.query.get(voucher_id)
        if not voucher:
            return jsonify({'success': False, 'message': 'السند غير موجود'}), 404
        
        if voucher.status == 'rejected':
            return jsonify({
                'success': False,
                'message': 'السند مرفوض بالفعل'
            }), 400
        
        if voucher.status == 'cancelled':
            return jsonify({
                'success': False,
                'message': 'لا يمكن رفض سند ملغى'
            }), 400
        
        # رفض السند
        voucher.status = 'rejected'
        voucher.rejected_at = datetime.now()
        voucher.rejected_by = rejected_by
        voucher.rejection_reason = rejection_reason
        
        # تسجيل العملية
        AuditLog.log_action(
            user_name=rejected_by,
            action='voucher_reject',
            entity_type='voucher',
            entity_id=voucher_id,
            entity_number=voucher.voucher_number,
            details=json.dumps({
                'voucher_type': voucher.voucher_type,
                'rejection_reason': rejection_reason,
                'amount_cash': float(voucher.amount_cash or 0),
                'amount_gold': float(voucher.amount_gold or 0)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم رفض السند',
            'voucher': voucher.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='voucher_reject',
            entity_type='voucher',
            entity_id=voucher_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/approve/batch', methods=['POST'])
@require_permission('voucher.approve')
def approve_vouchers_batch():
    """
    الموافقة على مجموعة سندات دفعة واحدة
    
    Body:
    {
        "voucher_ids": [1, 2, 3, ...]
    }
    """
    try:
        from models import Voucher
        
        data = request.get_json()
        approved_by = g.current_user.username
        voucher_ids = data.get('voucher_ids', [])
        
        if not voucher_ids:
            return jsonify({
                'success': False,
                'message': 'لم يتم تحديد أي سندات'
            }), 400
        
        approved_count = 0
        errors = []
        
        for voucher_id in voucher_ids:
            try:
                voucher = Voucher.query.get(voucher_id)
                if not voucher:
                    errors.append(f'السند {voucher_id} غير موجود')
                    continue
                
                if voucher.status != 'pending':
                    errors.append(f'السند {voucher.voucher_number} ليس بانتظار الموافقة')
                    continue
                
                voucher.status = 'approved'
                voucher.approved_at = datetime.now()
                voucher.approved_by = approved_by
                approved_count += 1
                
            except Exception as e:
                errors.append(f'خطأ في السند {voucher_id}: {str(e)}')
        
        # تسجيل العملية الجماعية
        AuditLog.log_action(
            user_name=approved_by,
            action='batch_voucher_approve',
            entity_type='voucher',
            entity_id=0,
            details=json.dumps({
                'approved_count': approved_count,
                'voucher_ids': voucher_ids,
                'errors': errors
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': f'تم الموافقة على {approved_count} سند',
            'approved_count': approved_count,
            'errors': errors
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/unapprove/<int:voucher_id>', methods=['POST'])
@require_permission('voucher.approve')
def unapprove_voucher(voucher_id):
    """
    إلغاء الموافقة على سند
    
    يتطلب صلاحية: voucher.approve
    """
    try:
        from models import Voucher
        
        unapproved_by = g.current_user.username
        
        voucher = Voucher.query.get(voucher_id)
        if not voucher:
            return jsonify({'success': False, 'message': 'السند غير موجود'}), 404
        
        if voucher.status != 'approved':
            return jsonify({
                'success': False,
                'message': 'السند ليس موافق عليه'
            }), 400
        
        # التحقق من أن السند لم يُستخدم في قيد محاسبي
        if voucher.journal_entry_id:
            return jsonify({
                'success': False,
                'message': 'لا يمكن إلغاء الموافقة لأن السند مرتبط بقيد محاسبي'
            }), 400
        
        # إلغاء الموافقة
        voucher.status = 'pending'
        voucher.approved_at = None
        voucher.approved_by = None
        
        # تسجيل العملية
        AuditLog.log_action(
            user_name=unapproved_by,
            action='voucher_unapprove',
            entity_type='voucher',
            entity_id=voucher_id,
            entity_number=voucher.voucher_number,
            details=json.dumps({
                'voucher_type': voucher.voucher_type,
                'amount_cash': float(voucher.amount_cash or 0),
                'amount_gold': float(voucher.amount_gold or 0)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم إلغاء الموافقة على السند',
            'voucher': voucher.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='voucher_unapprove',
            entity_type='voucher',
            entity_id=voucher_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/stats', methods=['GET'])
@require_permission('voucher.view')
def get_vouchers_stats():
    """إحصائيات السندات"""
    try:
        from models import Voucher
        
        # العدد حسب الحالة
        pending_count = Voucher.query.filter_by(status='pending').count()
        approved_count = Voucher.query.filter_by(status='approved').count()
        rejected_count = Voucher.query.filter_by(status='rejected').count()
        cancelled_count = Voucher.query.filter_by(status='cancelled').count()
        
        # العدد حسب النوع
        receipt_count = Voucher.query.filter_by(voucher_type='receipt').count()
        payment_count = Voucher.query.filter_by(voucher_type='payment').count()
        
        stats = {
            'by_status': {
                'pending': pending_count,
                'approved': approved_count,
                'rejected': rejected_count,
                'cancelled': cancelled_count
            },
            'by_type': {
                'receipt': receipt_count,
                'payment': payment_count
            },
            'total': pending_count + approved_count + rejected_count + cancelled_count
        }
        
        return jsonify({
            'success': True,
            'stats': stats
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500
