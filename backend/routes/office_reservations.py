"""Office-reservations domain routes — office_reservations_bp registered under /api in app.py."""
from __future__ import annotations

import json
from datetime import datetime, date, timedelta

from flask import Blueprint, g, jsonify, request
from sqlalchemy import func, and_, or_
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    Invoice,
    InvoiceKaratLine,
    JournalEntry,
    JournalEntryLine,
    Office,
    OfficeReservation,
    SafeBox,
    SafeBoxTransaction,
    Voucher,
    VoucherAccountLine,
)

from core.number_helpers import _coerce_float
from auth_decorators import require_permission

from pricing.karat_service import convert_to_main_karat, get_main_karat
from accounting.voucher_engine import (
    generate_voucher_number,
    create_journal_entry_from_voucher,
    _append_safe_transactions_for_voucher,
    _generate_journal_entry_number,
)
from accounting.mappings import get_account_id_for_mapping
from accounting.weight_closing import _auto_consume_weight_closing, _load_weight_closing_settings
from accounting.balances import _recalculate_account_balances_for_accounts
from accounting.safe_boxes import _rebuild_safe_box_transactions_for_journal_entry
from routes import (
    _upsert_weight_closing_order,
    _generate_reservation_code,
    _next_invoice_type_id,
    _resolve_account_from_id_or_number,
    _normalize_fk_ref,
)
from office_account_service import ensure_office_account
from office_supplier_service import ensure_office_supplier
from accounting.mappings import get_account_id_by_number
from dual_system_helpers import create_dual_journal_entry, verify_dual_balance

office_reservations_bp = Blueprint('office_reservations', __name__)

def _serialize_office_reservation(reservation: OfficeReservation):
    payload = reservation.to_dict()
    payload['office'] = reservation.office.to_dict() if reservation.office else None
    return payload

@office_reservations_bp.route('/office-reservations', methods=['GET'])
@require_permission('journal.post')
def list_office_reservations():
    query = OfficeReservation.query.options(joinedload(OfficeReservation.office))

    office_id = request.args.get('office_id', type=int)
    status = request.args.get('status')
    payment_status = request.args.get('payment_status')
    date_from = request.args.get('date_from')
    date_to = request.args.get('date_to')

    if office_id:
        query = query.filter(OfficeReservation.office_id == office_id)
    if status:
        query = query.filter(OfficeReservation.status == status)
    if payment_status:
        query = query.filter(OfficeReservation.payment_status == payment_status)
    if date_from:
        try:
            query = query.filter(OfficeReservation.reservation_date >= datetime.fromisoformat(date_from))
        except ValueError:
            return jsonify({'error': 'date_from must be ISO format'}), 400
    if date_to:
        try:
            query = query.filter(OfficeReservation.reservation_date <= datetime.fromisoformat(date_to))
        except ValueError:
            return jsonify({'error': 'date_to must be ISO format'}), 400

    order_by = request.args.get('order_by', 'reservation_date')
    order_direction = request.args.get('order_direction', 'desc').lower()
    order_map = {
        'reservation_date': OfficeReservation.reservation_date,
        'total_amount': OfficeReservation.total_amount,
        'paid_amount': OfficeReservation.paid_amount,
        'weight_main_karat': OfficeReservation.weight_main_karat,
    }
    sort_column = order_map.get(order_by, OfficeReservation.reservation_date)
    if order_direction == 'asc':
        query = query.order_by(sort_column.asc())
    else:
        query = query.order_by(sort_column.desc())

    limit = request.args.get('limit', type=int)
    page = request.args.get('page', type=int) or 1
    per_page = request.args.get('per_page', type=int) or limit or 25

    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    data = [_serialize_office_reservation(reservation) for reservation in pagination.items]

    return jsonify(
        {
            'data': data,
            'pagination': {
                'page': pagination.page,
                'per_page': pagination.per_page,
                'total': pagination.total,
                'pages': pagination.pages,
            },
        }
    )

@office_reservations_bp.route('/office-reservations/<int:reservation_id>', methods=['GET'])
@require_permission('journal.post')
def get_office_reservation(reservation_id):
    reservation = OfficeReservation.query.options(joinedload(OfficeReservation.office)).get(reservation_id)
    if not reservation:
        return jsonify({'error': 'الحجز غير موجود'}), 404
    return jsonify(_serialize_office_reservation(reservation))

@office_reservations_bp.route('/office-reservations', methods=['POST'])
@require_permission('journal.post')
def create_office_reservation():
    data = request.get_json(silent=True) or {}
    office_id = data.get('office_id')
    if not office_id:
        return jsonify({'error': 'office_id مطلوب'}), 400

    office = Office.query.get(office_id)
    if not office:
        return jsonify({'error': 'المكتب غير موجود'}), 404
    ensure_office_account(office)
    if not office.account_category_id:
        return jsonify({'error': 'المكتب لا يملك حساباً محاسبياً مرتبطاً'}), 400

    weight_grams = _coerce_float(data.get('weight') or data.get('weight_grams'))
    if weight_grams <= 0:
        return jsonify({'error': 'الوزن يجب أن يكون أكبر من صفر'}), 400

    price_per_gram = _coerce_float(data.get('price_per_gram'))
    if price_per_gram <= 0:
        return jsonify({'error': 'price_per_gram مطلوب'}), 400

    execution_price = _coerce_float(data.get('execution_price_per_gram'), price_per_gram)
    karat = int(data.get('karat') or get_main_karat())
    if karat not in (18, 21, 22, 24):
        return jsonify({'error': 'karat غير مدعوم. القيم المسموحة: 18, 21, 22, 24'}), 400
    weight_main_karat = round(convert_to_main_karat(weight_grams, karat), 6)
    total_amount = _coerce_float(data.get('total_amount'), round(weight_grams * price_per_gram, 2))

    # Important: treat explicit 0 as 0 (do NOT fall back to total_amount).
    if 'paid_amount' in data:
        paid_amount = _coerce_float(data.get('paid_amount'), 0.0)
    else:
        paid_amount = float(total_amount)

    payment_status = data.get('payment_status')
    if not payment_status:
        if paid_amount >= total_amount and total_amount > 0:
            payment_status = 'paid'
        elif paid_amount > 0:
            payment_status = 'partial'
        else:
            payment_status = 'pending'

    settings = _load_weight_closing_settings()

    try:
        reservation_date = datetime.fromisoformat(data.get('reservation_date')) if data.get('reservation_date') else datetime.now()
    except ValueError:
        return jsonify({'error': 'reservation_date يجب أن يكون بصيغة ISO'}), 400

    # ── guard: duplicate reservation within 24 hours ─────────────────────────
    if not data.get('force', False):
        cutoff = datetime.now() - timedelta(hours=24)
        dup = OfficeReservation.query.filter(
            OfficeReservation.office_id == office_id,
            OfficeReservation.weight_grams == weight_grams,
            OfficeReservation.price_per_gram == price_per_gram,
            OfficeReservation.status.in_(['approved', 'completed']),
            OfficeReservation.created_at >= cutoff,
        ).first()
        if dup:
            return jsonify({
                'error': 'duplicate_reservation',
                'message': (
                    f'يوجد حجز مشابه لنفس المكتب بنفس الوزن والسعر خلال آخر 24 ساعة '
                    f'(رقم الحجز: {dup.reservation_code}). '
                    'إذا كان هذا مقصوداً أرسل "force": true في الطلب.'
                ),
                'existing_reservation_id': dup.id,
                'existing_reservation_code': dup.reservation_code,
            }), 409

    try:
        supplier = ensure_office_supplier(office)
        supplier_override = data.get('supplier_id')
        if supplier_override and supplier_override != supplier.id:
            return jsonify({'error': 'لا يمكن تحديد مورد مختلف عن مورد المكتب'}), 400
        reservation = OfficeReservation(
            office_id=office.id,
            reservation_code=_generate_reservation_code(settings.get('reservation_code_prefix', 'RES')),
            reservation_date=reservation_date,
            karat=karat,
            weight_grams=weight_grams,
            weight_main_karat=weight_main_karat,
            price_per_gram=price_per_gram,
            execution_price_per_gram=execution_price,
            total_amount=total_amount,
            paid_amount=paid_amount,
            payment_status=payment_status,
            # Auto-approve on save: no separate approval step.
            status='approved',
            contact_person=data.get('contact_person'),
            contact_phone=data.get('contact_phone'),
            notes=data.get('notes'),
            weight_consumed_main_karat=0.0,
            weight_remaining_main_karat=weight_main_karat,
            purchase_invoice_id=None,
        )
        db.session.add(reservation)
        db.session.flush()
        voucher = None
        if paid_amount > 0:
            # Create a real Payment Voucher (سند صرف) for the paid amount.
            # This reflects money leaving the safe immediately, even if the gold is not received yet.
            resolved_payment_safe_box_id = (
                _normalize_fk_ref(data.get('safe_box_id'))
                or _normalize_fk_ref(data.get('cash_safe_box_id'))
                or _normalize_fk_ref(settings.get('cash_safe_box_id'))
            )

            safe_box = None
            cash_account = None
            if resolved_payment_safe_box_id is not None:
                safe_box = SafeBox.query.get(int(resolved_payment_safe_box_id))
                if not safe_box or not getattr(safe_box, 'is_active', True):
                    db.session.rollback()
                    return jsonify({'error': 'الخزينة المحددة غير موجودة/غير فعالة'}), 400
                if safe_box.safe_type not in ('cash', 'bank'):
                    db.session.rollback()
                    return jsonify({'error': 'الخزينة المحددة ليست خزينة نقد/بنك'}), 400
                cash_account = Account.query.get(safe_box.account_id)
                if not cash_account:
                    db.session.rollback()
                    return jsonify({'error': 'لا يمكن تسجيل الدفعة لأن حساب الخزينة غير موجود'}), 400
            else:
                # Backward-compatible fallback: allow posting against the configured cash account number/id.
                cash_account_setting = settings.get('cash_account_id', 1100)
                cash_account = _resolve_account_from_id_or_number(cash_account_setting)
                if not cash_account:
                    db.session.rollback()
                    return jsonify({'error': 'لا يمكن تسجيل الدفعة لأن حساب الصندوق غير موجود/غير مضبوط'}), 400

            voucher_number = generate_voucher_number('payment', voucher_date=reservation_date)
            voucher = Voucher(
                voucher_number=voucher_number,
                voucher_type='payment',
                date=reservation_date,
                party_type='supplier',
                supplier_id=supplier.id,
                description=f'عربون/دفعة حجز مكتب {office.name} ({reservation.reservation_code})',
                reference_type='office_reservation',
                reference_id=reservation.id,
                reference_number=str(reservation.reservation_code),
                created_by=str(data.get('created_by') or 'system'),
                status='approved',
                approved_by=str(data.get('created_by') or 'system'),
                approved_at=datetime.now(),
                amount_cash=round(float(paid_amount), 2),
                amount_gold=0.0,
            )
            db.session.add(voucher)
            db.session.flush()

            db.session.add(
                VoucherAccountLine(
                    voucher_id=voucher.id,
                    account_id=office.account_category_id,
                    line_type='debit',
                    amount_type='cash',
                    amount=round(float(paid_amount), 2),
                    description='دفعة حجز مكتب (مدين)',
                )
            )
            db.session.add(
                VoucherAccountLine(
                    voucher_id=voucher.id,
                    account_id=cash_account.id,
                    line_type='credit',
                    amount_type='cash',
                    amount=round(float(paid_amount), 2),
                    description='خروج نقدية من الصندوق (دائن)',
                )
            )
            db.session.flush()

            voucher_entry = create_journal_entry_from_voucher(voucher)
            if voucher_entry:
                voucher.journal_entry_id = voucher_entry.id
            _append_safe_transactions_for_voucher(voucher, created_by=voucher.created_by)

        # ── قيد الإنشاء الوزني: ذهب يغادر المخزون إلى المكتب ───────────────
        # يُسجَّل دائماً عند إنشاء الحجز بغض النظر عن حالة الدفع.
        # Dr. حساب وزني المكتب (مفكرة account_category_id) / Cr. مخزون كسر وزني (71310)
        #
        # NOTE (2026-06-23): كان هذا يحلّ الحساب عبر supplier.default_safe_box.account_id
        # -- مسار مستقل تماماً عن الجانب النقدي (الذي يستخدم office.account_category_id
        # مباشرة)، فينتج حسابين مختلفين لنفس المكتب (شوهد فعلياً: نقدي->1072،
        # وزني->1074، بينما 1072.memo_account_id=1213 الحساب الرسمي لم يُستخدَم
        # إطلاقاً). الإصلاح: استخدام نفس سلسلة المرجع account_category_id ->
        # memo_account_id المعتمدة في كل مكان آخر بالنظام (32 موضعاً في هذا
        # الملف)، مع الإبقاء على المسار القديم كـfallback فقط لمكتب لم يُضبط
        # له memo_account_id بعد، لا كمسار أساسي.
        _office_weight_acc_id = None
        try:
            _office_financial_acc = getattr(office, 'account_category', None)
            if _office_financial_acc and getattr(_office_financial_acc, 'memo_account_id', None):
                _office_weight_acc_id = _office_financial_acc.memo_account_id
        except Exception:
            pass

        if not _office_weight_acc_id:
            try:
                _gold_safe = getattr(supplier, 'default_safe_box', None)
                if _gold_safe and getattr(_gold_safe, 'safe_type', None) == 'gold':
                    _office_weight_acc_id = getattr(_gold_safe, 'account_id', None)
            except Exception:
                pass

        _inv_weight_acc = Account.query.filter_by(account_number='71310').first()
        _inv_weight_acc_id = _inv_weight_acc.id if _inv_weight_acc else None

        if _office_weight_acc_id and _inv_weight_acc_id and weight_grams > 0:
            _wgt_entry = JournalEntry(
                entry_number=_generate_journal_entry_number('WGT'),
                date=reservation_date,
                description=f'إرسال ذهب للحجز ({reservation.reservation_code}) - مكتب {office.name}',
                reference_type='office_reservation',
                reference_id=reservation.id,
                is_posted=True,
                posted_at=reservation_date,
                posted_by=str(data.get('created_by') or 'system'),
            )
            db.session.add(_wgt_entry)
            db.session.flush()

            _k_dr = f'debit_{karat}k'
            _k_cr = f'credit_{karat}k'
            db.session.add(JournalEntryLine(
                journal_entry_id=_wgt_entry.id,
                account_id=_office_weight_acc_id,
                description=f'ذهب بحيازة مكتب التسكير عيار {karat}',
                **{_k_dr: weight_grams},
            ))
            db.session.add(JournalEntryLine(
                journal_entry_id=_wgt_entry.id,
                account_id=_inv_weight_acc_id,
                description=f'خروج ذهب كسر للتسكير عيار {karat}',
                **{_k_cr: weight_grams},
            ))
            db.session.flush()

            # Mirror onto SafeBoxTransaction -- this entry is_posted=True
            # already, but without this the office's gold safe-box card
            # (and the transfer-between-safes availability check) never
            # see this inflow; they read SafeBoxTransaction, not the GL.
            try:
                _rebuild_safe_box_transactions_for_journal_entry(
                    _wgt_entry,
                    [l for l in _wgt_entry.lines if not getattr(l, 'is_deleted', False)],
                    created_by=str(data.get('created_by') or 'system'),
                )
            except Exception:
                pass

        office.total_reservations = (office.total_reservations or 0) + 1
        office.total_weight_purchased = (office.total_weight_purchased or 0.0) + weight_main_karat
        office.total_amount_paid = (office.total_amount_paid or 0.0) + paid_amount
        db.session.add(office)

        db.session.commit()

        response = _serialize_office_reservation(reservation)
        response['purchase_invoice_id'] = reservation.purchase_invoice_id
        # Echo payment safe box (if provided via request or settings) for UI/debugging.
        payment_sb = _normalize_fk_ref(data.get('safe_box_id')) or _normalize_fk_ref(data.get('cash_safe_box_id'))
        if payment_sb is not None:
            response['payment_safe_box_id'] = int(payment_sb)

        # Include voucher info (if any) so UI/support can trace the payment.
        try:
            if voucher is not None:
                response['payment_voucher_id'] = int(voucher.id)
                response['payment_voucher_number'] = str(voucher.voucher_number)
        except Exception:
            pass
        return jsonify(response), 201

    except Exception as exc:
        db.session.rollback()
        print(f"❌ Failed to create office reservation: {exc}")
        return jsonify({'error': f'فشل إنشاء الحجز: {exc}'}), 500

@office_reservations_bp.route('/office-reservations/<int:reservation_id>/settle', methods=['POST'])
@require_permission('journal.post')
def settle_office_reservation(reservation_id: int):
    """Convert an office reservation (fixing/booking) into a purchase invoice at execution time.

    Behavior:
    - Creates the purchase invoice + karat line.
    - Creates the gold journal entry (bridge vs office) and consumes weight closing orders.
    - Links any prior payment vouchers that referenced the reservation to the created invoice.
    """
    reservation = OfficeReservation.query.get(reservation_id)
    if not reservation:
        return jsonify({'error': 'الحجز غير موجود'}), 404

    if reservation.purchase_invoice_id:
        # Already settled.
        return jsonify(_serialize_office_reservation(reservation)), 200

    data = request.get_json(silent=True) or {}

    office = Office.query.get(reservation.office_id)
    if not office:
        return jsonify({'error': 'المكتب غير موجود'}), 404
    ensure_office_account(office)
    if not office.account_category_id:
        return jsonify({'error': 'المكتب لا يملك حساباً محاسبياً مرتبطاً'}), 400

    supplier = ensure_office_supplier(office)

    try:
        settlement_date = (
            datetime.fromisoformat(data.get('settlement_date'))
            if data.get('settlement_date')
            else datetime.now()
        )
    except ValueError:
        return jsonify({'error': 'settlement_date يجب أن يكون بصيغة ISO'}), 400

    execution_price = _coerce_float(
        data.get('execution_price_per_gram'),
        _coerce_float(getattr(reservation, 'execution_price_per_gram', None), _coerce_float(reservation.price_per_gram, 0.0)),
    )
    if execution_price <= 0:
        return jsonify({'error': 'execution_price_per_gram غير صالح'}), 400

    settings = _load_weight_closing_settings()

    try:
        legacy_supplier_purchase = 'شراء' + ' من ' + 'مورد'
        next_invoice_type_id = _next_invoice_type_id(['شراء', legacy_supplier_purchase])

        total_amount = float(getattr(reservation, 'total_amount', 0.0) or 0.0)
        paid_amount = float(getattr(reservation, 'paid_amount', 0.0) or 0.0)
        if total_amount <= 0:
            total_amount = round(float(reservation.weight_grams or 0.0) * float(reservation.price_per_gram or 0.0), 2)

        invoice_status = 'unpaid'
        if paid_amount >= total_amount and total_amount > 0:
            invoice_status = 'paid'
        elif paid_amount > 0:
            invoice_status = 'partially_paid'

        purchase_invoice = Invoice(
            invoice_type_id=next_invoice_type_id,
            supplier_id=supplier.id,
            office_id=office.id,
            date=settlement_date,
            total=total_amount,
            invoice_type='شراء',
            status=invoice_status,
            total_weight=float(reservation.weight_main_karat or 0.0),
            gold_subtotal=total_amount,
            wage_subtotal=0.0,
            gold_tax_total=0.0,
            wage_tax_total=0.0,
            amount_paid=paid_amount,
            gold_type='scrap',
        )
        db.session.add(purchase_invoice)
        db.session.flush()

        db.session.add(
            InvoiceKaratLine(
                invoice_id=purchase_invoice.id,
                karat=int(reservation.karat or get_main_karat()),
                weight_grams=float(reservation.weight_grams or 0.0),
                gold_value_cash=total_amount,
                manufacturing_wage_cash=0.0,
            )
        )

        _upsert_weight_closing_order(purchase_invoice, execution_price, settings=settings)

        reservation.purchase_invoice_id = purchase_invoice.id
        db.session.add(reservation)

        # Relink prior payment vouchers from reservation -> invoice for better traceability.
        try:
            linked = Voucher.query.filter_by(reference_type='office_reservation', reference_id=reservation.id).all()
            for v in linked:
                v.reference_type = 'invoice'
                v.reference_id = purchase_invoice.id
                v.reference_number = str(purchase_invoice.id)
                db.session.add(v)
        except Exception:
            pass

        gold_entry = JournalEntry(
            entry_number=_generate_journal_entry_number('WGT'),
            date=settlement_date,
            description=f'تنفيذ حجز ذهب ({reservation.reservation_code}) - مكتب {office.name}',
            reference_type='office_reservation',
            reference_id=reservation.id,
            is_posted=True,
            posted_at=settlement_date,
            posted_by=str(data.get('created_by') or 'system'),
        )
        db.session.add(gold_entry)
        db.session.flush()

        # حساب المشتريات (512 كسر / 511 جديد) — مدين نقداً
        _purchases_key = 'purchases_gold_scrap' if getattr(reservation, 'gold_type', 'scrap') == 'scrap' else 'purchases_gold_new'
        purchases_acc_id = (
            get_account_id_for_mapping('شراء من عميل', _purchases_key)
            or get_account_id_for_mapping('شراء من عميل', 'purchases_gold')
            or get_account_id_by_number('512')
            or get_account_id_by_number('511')
        )
        if not purchases_acc_id:
            db.session.rollback()
            return jsonify({'error': 'تعذر تحديد حساب المشتريات (511/512) لتسوية الحجز'}), 500

        karat = int(reservation.karat or get_main_karat())
        if karat not in (18, 21, 22, 24):
            karat = int(get_main_karat() or 21)
        if karat not in (18, 21, 22, 24):
            karat = 21

        weight_grams = float(reservation.weight_grams or 0.0)
        if weight_grams <= 0:
            db.session.rollback()
            return jsonify({'error': 'وزن الحجز غير صالح'}), 400

        # مدين: مشتريات ذهب (512/511) — تكلفة الشراء من المكتب
        create_dual_journal_entry(
            journal_entry_id=gold_entry.id,
            account_id=purchases_acc_id,
            cash_debit=total_amount,
            description=f'شراء ذهب تسكير عيار {karat} - مشتريات',
        )
        # دائن: حساب مورد المكتب — الدفع لاحقاً من خزينة المكتب
        create_dual_journal_entry(
            journal_entry_id=gold_entry.id,
            account_id=office.account_category_id,
            cash_credit=total_amount,
            supplier_id=supplier.id,
            description=f'مستحق لمكتب التسكير عيار {karat} - يُسدَّد من خزينة المكتب',
        )
        verify_dual_balance(gold_entry.id)

        consumption = _auto_consume_weight_closing(
            purchase_invoice.id,
            weight_override=float(reservation.weight_main_karat or 0.0),
            price_per_gram=execution_price,
            execution_type='office_reservation',
            journal_entry_id=gold_entry.id,
            notes=f'Office reservation #{reservation.reservation_code}',
        )

        weight_main_karat = float(reservation.weight_main_karat or 0.0)
        weight_consumed = float(consumption.get('weight_consumed') or 0.0)

        # In this workflow, settlement represents a real purchase/receipt of gold.
        # Weight-closing consumption is an internal matching mechanism and should not block execution.
        reservation.weight_consumed_main_karat = weight_main_karat
        reservation.weight_remaining_main_karat = 0.0
        reservation.executions_created = int(consumption.get('executions_created') or 0)
        reservation.status = 'completed'
        db.session.add(reservation)

        # Recompute stored Account.balance_* for accounts in the WGT entry.
        # The WGT JournalEntry is created with is_posted=True directly, so the
        # normal approve flow never fires — balance recalculation must happen here.
        try:
            _settle_affected_ids = {
                l.account_id for l in (gold_entry.lines or []) if l.account_id
            }
            if _settle_affected_ids:
                _recalculate_account_balances_for_accounts(list(_settle_affected_ids))
        except Exception as _rc_exc:
            print(f"⚠️ recalculate balances after settle skipped: {_rc_exc}")

        db.session.commit()

        response = _serialize_office_reservation(reservation)
        response['weight_consumption'] = consumption
        response['purchase_invoice_id'] = reservation.purchase_invoice_id
        response['journal_entry'] = {
            'id': gold_entry.id,
            'entry_number': gold_entry.entry_number,
            'date': gold_entry.date.isoformat() if gold_entry.date else settlement_date.isoformat(),
        }
        try:
            eps = 0.0001
            if weight_consumed + eps < weight_main_karat:
                response['weight_closing_warning'] = {
                    'message': 'تم تنفيذ الحجز، لكن لم يتم ربط/استهلاك وزن تسكير كافي (لا توجد أوامر تسكير مفتوحة كفاية).',
                    'weight_requested': round(weight_main_karat, 6),
                    'weight_consumed': round(weight_consumed, 6),
                }
        except Exception:
            pass
        return jsonify(response), 200

    except Exception as exc:
        db.session.rollback()
        print(f"❌ Failed to settle office reservation: {exc}")
        return jsonify({'error': f'فشل تنفيذ الحجز: {exc}'}), 500


def reverse_office_reservation_settlement_for_invoice(invoice, *, created_by=None):
    """The one atomic reversal workflow for undoing settle_office_reservation's
    effects on `invoice` — called by reject_invoice, which owns the
    transaction boundary (this function only flushes, never commits, so a
    failure partway through rolls back cleanly with the invoice's own
    status change).

    Reverses, in order:
      1. gold_entry — the purchase-recognition JournalEntry
         ('تنفيذ حجز ذهب...') settle_office_reservation created for this
         invoice. Mirrored with debit/credit swapped on each line (the same
         technique cancel_office_reservation already uses for the
         weight-transfer entry) rather than deleted or mutated, so both the
         original and its reversal stay visible for audit.
      2. weight-closing consumption — via the standalone
         reverse_weight_closing_executions_for_invoice primitive.
      3. the deposit voucher — re-tagged from reference_type='invoice' back
         to 'office_reservation', so settle_office_reservation's own
         existing relink query picks it up again on the next settle,
         without needing new relink logic.

    Idempotent: every step below is independently a no-op the second time
    (no unreversed gold_entry found; no WeightClosingExecution rows left;
    voucher already retagged) — safe to call more than once for the same
    invoice.

    Returns a summary dict for the caller to log/assert on.
    """
    from accounting.weight_closing import reverse_weight_closing_executions_for_invoice

    summary = {
        'invoice_id': invoice.id,
        'gold_entry_reversed': None,
        'weight_closing': None,
        'voucher_retagged': None,
    }

    reservation = OfficeReservation.query.filter_by(purchase_invoice_id=invoice.id).first()
    if reservation is None:
        # Not a reservation-sourced invoice — nothing for this workflow to do.
        return summary

    gold_entry = (
        JournalEntry.query
        .filter_by(reference_type='office_reservation', reference_id=reservation.id)
        .filter(JournalEntry.description.like('تنفيذ حجز ذهب%'))
        .filter(JournalEntry.is_deleted == False)
        .first()
    )
    already_reversed = JournalEntry.query.filter_by(
        reference_type='office_reservation_settlement_reversal', reference_id=invoice.id,
    ).first()

    if gold_entry is not None and already_reversed is None:
        original_lines = JournalEntryLine.query.filter_by(journal_entry_id=gold_entry.id).all()
        reversal_entry = JournalEntry(
            entry_number=_generate_journal_entry_number('WGT'),
            date=datetime.now(),
            description=f'عكس تسوية حجز ({reservation.reservation_code}) — رفض الفاتورة {invoice.id}',
            reference_type='office_reservation_settlement_reversal',
            reference_id=invoice.id,
            is_posted=True,
            posted_at=datetime.now(),
            posted_by=created_by or 'system',
        )
        db.session.add(reversal_entry)
        db.session.flush()

        affected_account_ids = set()
        for orig in original_lines:
            db.session.add(JournalEntryLine(
                journal_entry_id=reversal_entry.id,
                account_id=orig.account_id,
                cash_debit=orig.cash_credit or 0.0,
                cash_credit=orig.cash_debit or 0.0,
                description=f'عكس: {orig.description}' if orig.description else 'عكس تسوية حجز',
            ))
            affected_account_ids.add(orig.account_id)
        db.session.flush()

        if affected_account_ids:
            try:
                _recalculate_account_balances_for_accounts(list(affected_account_ids))
            except Exception as _rc_exc:
                print(f"⚠️ recalculate balances after settlement reversal skipped: {_rc_exc}")

        summary['gold_entry_reversed'] = gold_entry.id

    summary['weight_closing'] = reverse_weight_closing_executions_for_invoice(
        invoice.id, created_by=created_by,
    )

    deposit_voucher = Voucher.query.filter_by(
        reference_type='invoice', reference_id=invoice.id
    ).first()
    if deposit_voucher is not None:
        deposit_voucher.reference_type = 'office_reservation'
        deposit_voucher.reference_id = reservation.id
        deposit_voucher.reference_number = str(reservation.reservation_code)
        db.session.add(deposit_voucher)
        summary['voucher_retagged'] = deposit_voucher.id

    try:
        from models import AuditLog
        AuditLog.log_action(
            user_name=created_by or 'system',
            action='reverse_office_reservation_settlement',
            entity_type='invoice',
            entity_id=invoice.id,
            details=json.dumps(summary, ensure_ascii=False),
            success=True,
        )
    except Exception:
        pass

    return summary

@office_reservations_bp.route('/office-reservations/<int:reservation_id>/cancel', methods=['POST'])
@require_permission('journal.post')
def cancel_office_reservation(reservation_id: int):
    """Cancel an office reservation.

    This is intentionally conservative:
    - You cannot cancel a reservation after settlement (purchase_invoice_id exists).
    - You cannot cancel if any payment was recorded (paid_amount > 0 or payment voucher exists),
      because that would require a financial reversal workflow.
    """
    reservation = OfficeReservation.query.options(joinedload(OfficeReservation.office)).get(reservation_id)
    if not reservation:
        return jsonify({'error': 'الحجز غير موجود'}), 404

    if reservation.purchase_invoice_id:
        return jsonify({'error': 'لا يمكن إلغاء حجز تم تنفيذه'}), 400

    if (reservation.status or '').lower() == 'cancelled':
        return jsonify(_serialize_office_reservation(reservation)), 200

    paid_amount = float(getattr(reservation, 'paid_amount', 0.0) or 0.0)
    if paid_amount > 0:
        return jsonify({'error': 'لا يمكن إلغاء حجز عليه دفعات. قم بعمل سند عكس/استرجاع أولاً'}), 400

    try:
        linked_voucher = Voucher.query.filter_by(
            reference_type='office_reservation',
            reference_id=reservation.id,
        ).first()
    except Exception:
        linked_voucher = None

    if linked_voucher is not None:
        return jsonify({'error': 'لا يمكن إلغاء حجز مرتبط بسند دفع. قم بإلغاء السند أولاً'}), 400

    # ── قيد عكسي للوزن: إعادة الذهب من المكتب إلى مخزون الكسر ──────────
    try:
        wgt_je = (
            JournalEntry.query
            .filter_by(reference_type='office_reservation', reference_id=reservation.id)
            .filter(JournalEntry.entry_number.like('WGT-%'))
            .filter(JournalEntry.is_deleted.is_(False))
            .first()
        )
        if wgt_je:
            orig_lines = JournalEntryLine.query.filter_by(journal_entry_id=wgt_je.id).all()
            rev_entry = JournalEntry(
                entry_number=_generate_journal_entry_number('WGT'),
                date=datetime.now(),
                description=f'إلغاء حجز ({reservation.reservation_code}) — قيد عكسي',
                reference_type='office_reservation',
                reference_id=reservation.id,
                is_posted=True,
                posted_at=datetime.now(),
                posted_by='cancel',
            )
            db.session.add(rev_entry)
            db.session.flush()

            affected_account_ids = set()
            karats = (18, 21, 22, 24)
            for orig in orig_lines:
                rev_kwargs = {'journal_entry_id': rev_entry.id, 'account_id': orig.account_id, 'description': orig.description}
                for k in karats:
                    d = getattr(orig, f'debit_{k}k') or 0.0
                    c = getattr(orig, f'credit_{k}k') or 0.0
                    if d:
                        rev_kwargs[f'credit_{k}k'] = d
                    if c:
                        rev_kwargs[f'debit_{k}k'] = c
                db.session.add(JournalEntryLine(**rev_kwargs))
                affected_account_ids.add(orig.account_id)

            db.session.flush()
            if affected_account_ids:
                _recalculate_account_balances_for_accounts(list(affected_account_ids))
    except Exception as _exc:
        import traceback; traceback.print_exc()
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء القيد العكسي: {_exc}'}), 500

    reservation.status = 'cancelled'
    db.session.add(reservation)
    db.session.commit()

    return jsonify(_serialize_office_reservation(reservation)), 200

