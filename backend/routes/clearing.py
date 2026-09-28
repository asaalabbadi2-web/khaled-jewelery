"""Clearing & weight-closing domain routes — clearing_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, date, timedelta

from flask import Blueprint, current_app, g, jsonify, request
from sqlalchemy import func, and_, or_, case
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    Invoice,
    InvoicePayment,
    JournalEntry,
    PaymentMethod,
    SafeBox,
    SafeBoxTransaction,
    Settings,
    SettlementLine,
    Supplier,
    Voucher,
    VoucherAccountLine,
    WeightClosingExecution,
    WeightClosingOrder,
)

from core.number_helpers import _coerce_float
from auth_decorators import require_permission

from services.live_balances import live_balances_by_account_ids

from pricing.karat_service import convert_from_main_karat, convert_to_main_karat, get_main_karat
from accounting.voucher_engine import (
    generate_voucher_number,
    create_journal_entry_from_voucher,
    _append_safe_transactions_for_voucher,
    _generate_journal_entry_number,
)
from accounting.mappings import get_account_id_for_mapping
from accounting.weight_closing import _auto_consume_weight_closing, _load_weight_closing_settings
from dual_system_helpers import create_dual_journal_entry, verify_dual_balance
from settlement_state_service import get_settled_amounts
from services.weight_execution import resolve_weight_profile
from allocation_service import AllocationService
from routes import (
    get_current_gold_price,
    _resolve_account_from_id_or_number,
    _record_memo_weight_transfer,
    ensure_weight_closing_support_accounts,
)

clearing_bp = Blueprint('clearing', __name__)


# ---------------------------------------------------------------------------
# Which payments may be settled -- ONE rule, owned by the scheduler module.
# This screen used to carry its own copy of the selection: after AV-2026-00436
# was reversed it listed rejected invoice 3123's 2,150.00 next to 3124's, and a
# manual settlement accepted whatever payment ids were ticked.
# ---------------------------------------------------------------------------

def _settleable_ip_ids_for_box(safe_box_id) -> list[int]:
    """Ids of every payment into *safe_box_id* that may still be settled.
    Whether each is ALREADY settled is a separate question (SettlementLine)."""
    from clearing_settlement_scheduler import settleable_payments_query
    return [ip.id for ip in settleable_payments_query(int(safe_box_id)).all()]


def _refuse_unsettleable_payment_ids(safe_box_id, ids) -> list[int]:
    """The subset of *ids* that must not be settled into *safe_box_id*: a payment
    on a retracted invoice, one whose voucher was cancelled, or one that does
    not belong to this clearing box at all."""
    wanted = [int(i) for i in (ids or [])]
    if not wanted:
        return []
    from clearing_settlement_scheduler import settleable_payments_query
    allowed = {
        ip.id for ip in settleable_payments_query(int(safe_box_id))
        .filter(InvoicePayment.id.in_(wanted)).all()
    }
    return [i for i in wanted if i not in allowed]


def _unsettled_invoice_payment_sbts(clearing_safe_box_id):
    """Per-transaction settlement's candidates: incoming invoice_payment movements
    into the clearing box, excluding those of a retracted invoice.

    Narrower than settleable_payments_query on purpose: this legacy path is
    driven by SafeBoxTransaction, not InvoicePayment, so only the invoice rule
    can be applied here without the consolidation recorded as a known gap.
    """
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
    return (
        SafeBoxTransaction.query
        .outerjoin(Invoice, Invoice.id == SafeBoxTransaction.invoice_id)
        .filter(
            SafeBoxTransaction.safe_box_id == clearing_safe_box_id,
            SafeBoxTransaction.ref_type == 'invoice_payment',
            SafeBoxTransaction.direction == 'in',
            or_(
                SafeBoxTransaction.invoice_id.is_(None),
                func.lower(func.coalesce(Invoice.status, '')).notin_(
                    list(RETRACTED_INVOICE_STATUSES)),
            ),
        )
        .order_by(SafeBoxTransaction.created_at.asc())
        .all()
    )

def _compute_clearing_due_amount(safe_box_id):
    """Compute how much is actually pending in a clearing safe box.

    Uses SettlementLine-based calculation (primary) plus transfer-in
    adjustment (secondary) to avoid false zeros caused by accounting gaps.

    The previous cash-flow formula (ip_in - voucher_out) broke when
    voucher_out exceeded SL coverage due to historical allocation gaps
    (e.g. AV-2026-00133: voucher=19,710 but SL=13,660, gap=6,050).
    That 6,050 inflated voucher_out until it equalled ip_in, making
    due=0 and hiding all genuinely-pending IPs via the FIFO mechanism.

    New formula:
        pending_sl = sum(IP.amount - SL_settled) for all IPs with SL_settled < IP.amount
        due = pending_sl + net_transfer_in
    """
    # ── Primary: SL-based pending ────────────────────────────────────────────
    # All IPs for this safe box
    all_ip_ids: list[int] = [
        r[0]
        for r in (
            db.session.query(InvoicePayment.id)
            .join(PaymentMethod, PaymentMethod.id == InvoicePayment.payment_method_id)
            .filter(PaymentMethod.default_safe_box_id == safe_box_id)
            .all()
        )
    ]

    if not all_ip_ids:
        return 0.0

    # Settled per IP (approved vouchers only — excludes cancelled/phantom SLs)
    sl_rows = (
        db.session.query(
            SettlementLine.invoice_payment_id,
            func.coalesce(func.sum(SettlementLine.amount_settled), 0.0),
        )
        .join(Voucher, Voucher.id == SettlementLine.voucher_id)
        .filter(
            SettlementLine.invoice_payment_id.in_(all_ip_ids),
            Voucher.status == 'approved',
        )
        .group_by(SettlementLine.invoice_payment_id)
        .all()
    )
    sl_settled: dict[int, float] = {r[0]: round(float(r[1]), 2) for r in sl_rows}

    ip_amounts: dict[int, float] = {
        r[0]: round(float(r[1]), 2)
        for r in (
            db.session.query(InvoicePayment.id, InvoicePayment.amount)
            .filter(InvoicePayment.id.in_(all_ip_ids))
            .all()
        )
    }

    pending_sl = round(sum(
        max(0.0, ip_amounts[ip_id] - sl_settled.get(ip_id, 0.0))
        for ip_id in all_ip_ids
    ), 2)

    # ── Secondary: safe-box transfers without IP (routing corrections) ────────
    transfer_in = (
        db.session.query(func.coalesce(func.sum(SafeBoxTransaction.amount_cash), 0.0))
        .filter(
            SafeBoxTransaction.safe_box_id == safe_box_id,
            SafeBoxTransaction.ref_type == 'voucher',
            SafeBoxTransaction.direction == 'in',
            SafeBoxTransaction.invoice_payment_id.is_(None),
        )
        .scalar()
    ) or 0.0

    reversal_out = (
        db.session.query(func.coalesce(func.sum(SafeBoxTransaction.amount_cash), 0.0))
        .filter(
            SafeBoxTransaction.safe_box_id == safe_box_id,
            SafeBoxTransaction.ref_type == 'voucher_reversal',
            SafeBoxTransaction.direction == 'out',
            SafeBoxTransaction.invoice_payment_id.is_(None),
        )
        .scalar()
    ) or 0.0

    net_transfer_in = max(0.0, float(transfer_in) - float(reversal_out))

    return round(pending_sl + net_transfer_in, 2)

def _create_clearing_settlement_voucher(
    *,
    clearing_safe_box_id,
    bank_safe_box_id,
    gross_amount,
    fee_amount=0.0,
    fee_is_net=True,
    commission_vat_account_id=None,
    settlement_dt=None,
    reference_number=None,
    created_by='system',
    fee_account_id=None,
    description_override=None,
    notes=None,
    ensure_unique_reference: bool = False,
    allow_continuation: bool = False,
    invoice_payment_ids=None,
):
    """Core implementation for clearing settlement.

    This is shared between the HTTP endpoint and the scheduler job.

    allow_continuation: only meaningful when ensure_unique_reference=True and a
    prior voucher with this reference already exists. The caller must have
    already independently confirmed (from SettlementLine-based remaining-due
    data, not from voucher existence) that a genuine unsettled amount remains
    for this reference's period — e.g. the scheduler's daily loop checks
    _compute_due_for_day() > 0 before ever reaching this call. A prior voucher
    means that period was attempted before, not that it was fully covered:
    gross_amount can be capped by running_balance/running_cap mid-loop, which
    deliberately leaves the newest IPs of that period without a SettlementLine
    so they stay visible as pending. When allow_continuation is True, this
    function creates a new, independent voucher (own id/journal entry/
    approval — the prior voucher is never modified) reusing the same
    reference_number as a grouping label, and records which prior voucher(s)
    it continues in `notes` for traceability (non-authoritative — nothing
    depends on that text). Defaults to False so every other caller (manual
    HTTP trigger, per-transaction path) keeps today's exact skip-on-duplicate
    behavior.
    """
    if not clearing_safe_box_id or not bank_safe_box_id:
        raise ValueError('missing_required_fields')

    try:
        gross_amount = float(gross_amount or 0.0)
        fee_amount = float(fee_amount or 0.0)
    except (TypeError, ValueError):
        raise ValueError('invalid_amounts')

    if gross_amount <= 0:
        raise ValueError('gross_amount_must_be_positive')
    if fee_amount < 0:
        raise ValueError('fee_amount_must_be_non_negative')

    # نحتسب ضريبة العمولة عند التسوية لأن النسبة المدخلة صافي ضريبة
    # fee_is_net=True يعني أن fee_amount صافي بدون ضريبة قيمة مضافة
    # إذا كانت الضريبة معطلة في الإعدادات، تكون zero
    def _normalize_tax_rate(raw_value, fallback=0.15):
        try:
            val = float(raw_value)
        except Exception:
            val = float(fallback)
        if val > 1.0:
            val = val / 100.0
        if val < 0:
            val = abs(val)
        return val

    settings_row = None
    try:
        settings_row = Settings.query.first()
    except Exception:
        settings_row = None

    tax_enabled = True
    vat_rate = 0.15
    try:
        tax_enabled = bool(getattr(settings_row, 'tax_enabled', True)) if settings_row else True
        vat_rate = _normalize_tax_rate(getattr(settings_row, 'tax_rate', 0.15) if settings_row else 0.15, fallback=0.15)
    except Exception:
        tax_enabled = True
        vat_rate = 0.15

    fee_vat = 0.0
    if fee_is_net and tax_enabled and fee_amount > 0:
        fee_vat = round(fee_amount * vat_rate, 2)

    net_amount = round(gross_amount - fee_amount - fee_vat, 2)
    if net_amount < 0:
        raise ValueError('fee_amount_exceeds_gross')

    if settlement_dt is None:
        settlement_dt = datetime.now()

    # قفل صف خزينة المقاصة هنا (لا في أي مستدعٍ) كي يحصل كل المستدعين
    # (سكدولر، API اليدوي، أي مستدعٍ مستقبلي) على نفس الحماية ضد تشغيل
    # متزامن يقرأ "المتبقي الحالي" قبل أن يلتزم تشغيل آخر تغييراته —
    # يُحرَّر تلقائياً عند commit/rollback في المستدعي.
    clearing_safe_box = (
        SafeBox.query.filter_by(id=clearing_safe_box_id)
        .with_for_update()
        .first()
    )
    if not clearing_safe_box or not clearing_safe_box.is_active:
        raise ValueError('not_found:clearing_safe_box')

    bank_safe_box = SafeBox.query.get(bank_safe_box_id)
    if not bank_safe_box or not bank_safe_box.is_active:
        raise ValueError('not_found:bank_safe_box')

    if (clearing_safe_box.safe_type or '').strip().lower() != 'clearing':
        raise ValueError('invalid_safe_type:clearing')
    if (bank_safe_box.safe_type or '').strip().lower() != 'bank':
        raise ValueError('invalid_safe_type:bank')

    # Optional idempotency for scheduler jobs
    prior_vouchers_same_reference = []
    if ensure_unique_reference and reference_number:
        prior_vouchers_same_reference = Voucher.query.filter_by(
            reference_type='clearing_settlement',
            reference_number=reference_number,
        ).order_by(Voucher.id.asc()).all()
        if prior_vouchers_same_reference and not allow_continuation:
            existing = prior_vouchers_same_reference[0]
            return {
                'success': True,
                'voucher': existing.to_dict(),
                'balances': {},
                'skipped': True,
                'skip_reason': 'already_exists',
            }
        # allow_continuation=True: a prior voucher for this reference exists,
        # but the caller has already confirmed (via SettlementLine-based
        # remaining-due data) that a genuine unsettled amount remains. Fall
        # through and create a new, independent voucher — see docstring.

    # HARD GUARD (anti double-deduction):
    # If the clearing safe box is the default safe for one or more payment methods,
    # and those methods record commission at invoice time, then fee must be zero here.
    if fee_amount > 0:
        try:
            matched_methods = (
                PaymentMethod.query
                .filter_by(default_safe_box_id=clearing_safe_box.id, is_active=True)
                .all()
            )
        except Exception:
            matched_methods = []

        if matched_methods:
            timings = set()
            for pm in matched_methods:
                try:
                    t = str(getattr(pm, 'commission_timing', 'invoice') or 'invoice').strip().lower()
                except Exception:
                    t = 'invoice'
                if t not in {'invoice', 'settlement'}:
                    t = 'invoice'
                timings.add(t)

            if 'invoice' in timings:
                raise ValueError('fee_not_allowed_when_commission_timing_invoice')

    clearing_account = clearing_safe_box.account
    bank_account = bank_safe_box.account
    if not clearing_account or not bank_account:
        raise ValueError('safe_box_missing_account')

    fee_account = None
    if fee_amount > 0:
        if not fee_account_id:
            # Auto-resolve from the PaymentMethod linked to this clearing safe.
            # Use joinedload to fetch fee_expense_account in one query (avoids N+1).
            matched_pm = (
                PaymentMethod.query
                .options(joinedload(PaymentMethod.fee_expense_account))
                .filter_by(default_safe_box_id=clearing_safe_box_id)
                .first()
            )
            if matched_pm and getattr(matched_pm, 'fee_expense_account_id', None):
                fee_account_id = matched_pm.fee_expense_account_id
            else:
                # Fall back to a generic commission-expense account if it exists
                generic = (
                    Account.query.filter_by(account_number='5100').first()
                    or Account.query.filter_by(account_number='5110').first()
                    or Account.query.filter_by(account_number='5113').first()
                )
                if generic:
                    fee_account_id = generic.id

        if not fee_account_id:
            raise ValueError('fee_account_id_required')
        fee_account = Account.query.get(fee_account_id)
        if not fee_account:
            raise ValueError('not_found:fee_account')

    commission_vat_account = None
    if fee_vat > 0:
        # Prefer a dedicated account for VAT on commissions; if not configured,
        # fall back to the generic VAT receivable (input VAT) account.
        commission_vat_account_id = (
            commission_vat_account_id
            or get_account_id_for_mapping('بيع', 'commission_vat')
            or _get_default_account_id('commission_vat')
        )
        if commission_vat_account_id:
            commission_vat_account = Account.query.get(commission_vat_account_id)

        if not commission_vat_account:
            fallback_vat_id = (
                get_account_id_for_mapping('بيع', 'vat_receivable')
                or _get_default_account_id('vat_receivable')
            )
            if fallback_vat_id:
                commission_vat_account = Account.query.get(fallback_vat_id)

        if not commission_vat_account:
            raise ValueError('commission_vat_account_not_found')

    def _live_cash_balance(account_obj, fallback=0.0):
        account_id = getattr(account_obj, 'id', None)
        if account_id is None:
            return float(fallback or 0.0)
        try:
            live = live_balances_by_account_ids([int(account_id)]).get(int(account_id))
            if isinstance(live, dict):
                return float(live.get('cash') or 0.0)
        except Exception:
            pass
        return float(fallback or 0.0)

    clearing_balance = _live_cash_balance(
        clearing_account,
        fallback=float(getattr(clearing_account, 'balance_cash', 0.0) or 0.0),
    )
    if clearing_balance < gross_amount:
        raise ValueError('insufficient_clearing_balance')

    # Due-amount guard: prevent settling more than what's actually owed.
    due_amount = _compute_clearing_due_amount(clearing_safe_box_id)
    if due_amount < 0.01:
        raise ValueError('no_due_amount')
    if gross_amount > due_amount + 0.01:
        raise ValueError(f'exceeds_due_amount:{due_amount:.2f}')

    voucher_number = generate_voucher_number('adjustment', voucher_date=settlement_dt)

    if description_override:
        description = description_override
    else:
        description = (
            f'تسوية مستحقات تحصيل: {clearing_safe_box.name} → {bank_safe_box.name} '
            f'(إجمالي {gross_amount:.2f}، عمولة {fee_amount:.2f}، صافي {net_amount:.2f})'
        )

    final_notes = (notes or '').strip()
    if prior_vouchers_same_reference:
        # تتبّع نصي بحت (غير معتمَد من أي منطق) — للتدقيق البشري فقط:
        # رقم الدفعة وأسلاف نفس المرجع محسوبان من السندات الموجودة، لا قيمة مخزَّنة منفصلة.
        prior_numbers = ', '.join(v.voucher_number for v in prior_vouchers_same_reference)
        continuation_note = (
            f'دفعة تكميلية #{len(prior_vouchers_same_reference) + 1} لمرجع {reference_number} '
            f'— يتبع: {prior_numbers}'
        )
        final_notes = f'{final_notes}\n{continuation_note}'.strip()

    voucher = Voucher(
        voucher_number=voucher_number,
        voucher_type='adjustment',
        date=settlement_dt,
        description=description,
        reference_type='clearing_settlement',
        reference_id=clearing_safe_box_id,
        reference_number=reference_number,
        notes=final_notes or None,
        created_by=created_by,
        status='approved',
        approved_by=created_by,
        approved_at=datetime.now(),
        amount_cash=round(gross_amount, 2),
        amount_gold=0.0,
    )
    db.session.add(voucher)
    db.session.flush()

    if net_amount > 0:
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=bank_account.id,
            line_type='debit',
            amount_type='cash',
            amount=round(net_amount, 2),
            description=f'إيداع صافي تسوية مستحقات إلى {bank_safe_box.name}',
        ))

    if fee_amount > 0 and fee_account:
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=fee_account.id,
            line_type='debit',
            amount_type='cash',
            amount=round(fee_amount, 2),
            description='عمولة تحصيل (صافي)',
        ))

    if fee_vat > 0 and commission_vat_account:
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=commission_vat_account.id,
            line_type='debit',
            amount_type='cash',
            amount=round(fee_vat, 2),
            description='ضريبة قيمة مضافة على عمولة التحصيل',
        ))

    db.session.add(VoucherAccountLine(
        voucher_id=voucher.id,
        account_id=clearing_account.id,
        line_type='credit',
        amount_type='cash',
        amount=round(gross_amount, 2),
        description='إقفال مستحقات التحصيل',
    ))

    db.session.flush()

    journal_entry = create_journal_entry_from_voucher(voucher)
    if journal_entry:
        voucher.journal_entry_id = journal_entry.id

    _append_safe_transactions_for_voucher(voucher, created_by=created_by)

    clearing_account.update_balance(cash_amount=-gross_amount)
    bank_account.update_balance(cash_amount=net_amount)
    if fee_account:
        fee_account.update_balance(cash_amount=fee_amount)
    if commission_vat_account:
        commission_vat_account.update_balance(cash_amount=fee_vat)

    # --- Per-transaction settlement lines ---
    AllocationService().allocate(
        voucher=voucher,
        invoice_payment_ids=invoice_payment_ids or [],
        gross_amount=gross_amount,
        fee_amount=fee_amount,
        fee_vat=fee_vat,
    )

    return {
        'success': True,
        'voucher': voucher.to_dict(),
        'balances': {
            'clearing_account_cash': round(_live_cash_balance(clearing_account, fallback=float(getattr(clearing_account, 'balance_cash', 0.0) or 0.0)), 2),
            'bank_account_cash': round(_live_cash_balance(bank_account, fallback=float(getattr(bank_account, 'balance_cash', 0.0) or 0.0)), 2),
            **({'fee_account_cash': round(_live_cash_balance(fee_account, fallback=float(getattr(fee_account, 'balance_cash', 0.0) or 0.0)), 2)} if fee_account else {}),
            **({'commission_vat_account_cash': round(_live_cash_balance(commission_vat_account, fallback=float(getattr(commission_vat_account, 'balance_cash', 0.0) or 0.0)), 2)} if commission_vat_account else {}),
        }
    }

@clearing_bp.route('/clearing/settlements', methods=['POST'])
@require_permission('vouchers.create')
def create_clearing_settlement():
    """Create a clearing settlement voucher and update balances.

    Best practice flow:
    - Credit: Clearing receivable (gross)
    - Debit: Bank (net)
    - Debit: Commission expense (fee)

    Body:
      - clearing_safe_box_id: int (required) (alias: from_safe_box_id)
      - bank_safe_box_id: int (required) (alias: to_safe_box_id)
      - gross_amount: float (required) (alias: amount)
      - fee_amount: float (optional, default 0) (alias: fee)
      - settlement_date: ISO datetime/date (optional)
      - reference_number: str (optional)
      - created_by: str (optional)
      - fee_account_id: int (required if fee_amount > 0)
      - description: str (optional)
    """
    data = request.get_json(silent=True) or {}

    clearing_safe_box_id = data.get('clearing_safe_box_id') or data.get('from_safe_box_id')
    bank_safe_box_id = data.get('bank_safe_box_id') or data.get('to_safe_box_id')
    created_by = data.get('created_by', 'system')
    reference_number = data.get('reference_number')
    description_override = (data.get('description') or '').strip() or None
    fee_is_net = bool(data.get('fee_is_net', True))
    commission_vat_account_id = data.get('commission_vat_account_id')

    # Parse settlement date
    settlement_date_raw = data.get('settlement_date') or data.get('date')
    settlement_dt = datetime.now()
    if settlement_date_raw:
        try:
            if isinstance(settlement_date_raw, str) and len(settlement_date_raw) == 10:
                settlement_dt = datetime.fromisoformat(settlement_date_raw + 'T00:00:00')
            else:
                settlement_dt = datetime.fromisoformat(settlement_date_raw)
        except Exception:
            return jsonify({'error': 'invalid settlement_date'}), 400

    if clearing_safe_box_id and data.get('invoice_payment_ids'):
        refused = _refuse_unsettleable_payment_ids(clearing_safe_box_id, data.get('invoice_payment_ids'))
        if refused:
            return jsonify({
                'error': 'unsettleable_payments',
                'message': 'لا يمكن تسوية دفعات تخص فاتورة ملغاة أو سندًا ملغى أو خزينة أخرى. '
                           'أزلها من التحديد ثم أعد المحاولة.',
                'invoice_payment_ids': refused,
            }), 400

    try:
        result = _create_clearing_settlement_voucher(
            clearing_safe_box_id=clearing_safe_box_id,
            bank_safe_box_id=bank_safe_box_id,
            gross_amount=(data.get('gross_amount') or data.get('amount') or 0.0),
            fee_amount=(data.get('fee_amount') or data.get('fee') or 0.0),
            fee_is_net=fee_is_net,
            commission_vat_account_id=commission_vat_account_id,
            settlement_dt=settlement_dt,
            reference_number=reference_number,
            created_by=created_by,
            fee_account_id=data.get('fee_account_id'),
            description_override=description_override,
            notes=(data.get('notes') or ''),
            invoice_payment_ids=data.get('invoice_payment_ids'),
        )
        db.session.commit()
        return jsonify(result), 201

    except ValueError as exc:
        db.session.rollback()
        msg = str(exc)
        if msg.startswith('not_found:'):
            which = msg.split(':', 1)[1]
            if which == 'clearing_safe_box':
                return jsonify({'error': 'Clearing safe box not found or inactive'}), 404
            if which == 'bank_safe_box':
                return jsonify({'error': 'Bank safe box not found or inactive'}), 404
            if which == 'fee_account':
                return jsonify({'error': 'fee_account_id not found'}), 404
            return jsonify({'error': 'not_found'}), 404

        if msg == 'missing_required_fields':
            return jsonify({'error': 'clearing_safe_box_id and bank_safe_box_id are required'}), 400
        if msg == 'invalid_amounts':
            return jsonify({'error': 'invalid gross_amount/fee_amount'}), 400
        if msg == 'gross_amount_must_be_positive':
            return jsonify({'error': 'gross_amount must be > 0'}), 400
        if msg == 'fee_amount_must_be_non_negative':
            return jsonify({'error': 'fee_amount must be >= 0'}), 400
        if msg == 'fee_amount_exceeds_gross':
            return jsonify({'error': 'fee_amount cannot exceed gross_amount'}), 400
        if msg.startswith('invalid_safe_type:'):
            which = msg.split(':', 1)[1]
            if which == 'clearing':
                return jsonify({'error': 'clearing_safe_box must be of type clearing'}), 400
            if which == 'bank':
                return jsonify({'error': 'bank_safe_box must be of type bank'}), 400
            return jsonify({'error': 'invalid_safe_type'}), 400
        if msg == 'safe_box_missing_account':
            return jsonify({'error': 'Safe box must be linked to an account'}), 400
        if msg == 'fee_account_id_required':
            return jsonify({'error': 'fee_account_id is required for fee_amount > 0'}), 400
        if msg == 'no_due_amount':
            return jsonify({
                'error': 'no_due_amount',
                'message': 'لا يوجد مبلغ مستحق للتسوية في هذه الخزينة — قد تكون جميع الدفعات تمت تسويتها مسبقاً.',
                'due_amount': 0.0,
            }), 400
        if msg.startswith('exceeds_due_amount:'):
            due_str = msg.split(':', 1)[1]
            return jsonify({
                'error': 'exceeds_due_amount',
                'message': f'المبلغ المطلوب يتجاوز المبلغ المستحق للتسوية ({due_str} ر.س)',
                'due_amount': float(due_str),
                'gross_amount': round(float(data.get('gross_amount') or data.get('amount') or 0.0), 2),
            }), 400
        if msg == 'insufficient_clearing_balance':
            try:
                clearing_safe_box_id = data.get('clearing_safe_box_id') or data.get('from_safe_box_id')
                clearing_safe_box = SafeBox.query.get(clearing_safe_box_id)
                clearing_account = getattr(clearing_safe_box, 'account', None)
                if clearing_account and getattr(clearing_account, 'id', None) is not None:
                    live = live_balances_by_account_ids([int(clearing_account.id)]).get(int(clearing_account.id))
                    clearing_balance = float((live or {}).get('cash') or 0.0)
                else:
                    clearing_balance = 0.0
            except Exception:
                clearing_balance = 0.0
            gross_amount = float(data.get('gross_amount') or data.get('amount') or 0.0)
            return jsonify({
                'error': 'Clearing balance is insufficient for settlement',
                'clearing_balance': round(clearing_balance, 2),
                'gross_amount': round(gross_amount, 2),
            }), 400

        if msg == 'fee_not_allowed_when_commission_timing_invoice':
            # Preserve richer error payload for client UX
            try:
                clearing_safe_box = SafeBox.query.get(clearing_safe_box_id)
            except Exception:
                clearing_safe_box = None
            methods_payload = []
            try:
                if clearing_safe_box:
                    matched = (
                        PaymentMethod.query
                        .filter_by(default_safe_box_id=clearing_safe_box.id, is_active=True)
                        .all()
                    )
                    for pm in matched:
                        try:
                            t = str(getattr(pm, 'commission_timing', 'invoice') or 'invoice').strip().lower()
                        except Exception:
                            t = 'invoice'
                        if t not in {'invoice', 'settlement'}:
                            t = 'invoice'
                        methods_payload.append({'id': pm.id, 'name': pm.name, 'commission_timing': t})
            except Exception:
                methods_payload = []

            return jsonify({
                'error': 'fee_not_allowed_when_commission_timing_invoice',
                'message': (
                    'لا يمكن إرسال عمولة (fee) في التسوية لأن سياسة العمولة لهذه الخزينة '
                    'تسجل العمولة ضمن الفاتورة (commission_timing=invoice) أو توجد سياسات متضاربة. '
                    'لمنع خصم العمولة مرتين: اجعل fee=0 أو غيّر سياسة وسيلة الدفع إلى settlement '
                    'أو استخدم خزينة مستحقات منفصلة لكل سياسة.'
                ),
                'clearing_safe_box_id': clearing_safe_box.id if clearing_safe_box else clearing_safe_box_id,
                'fee_amount': round(float(data.get('fee_amount') or data.get('fee') or 0.0), 2),
                'payment_methods': methods_payload,
            }), 400

        return jsonify({'error': 'validation_error', 'message': msg}), 400

    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'Failed to create clearing settlement: {str(exc)}'}), 500

# =========================================================================
# Per-Transaction Clearing Settlement (one voucher per invoice payment)
# =========================================================================

@clearing_bp.route('/clearing/settlements/per-transaction', methods=['POST'])
@require_permission('vouchers.create')
def create_per_transaction_clearing_settlement():
    """Create individual clearing settlement vouchers — one per unsettled
    invoice payment in a clearing safe box.

    Body:
      - clearing_safe_box_id: int (required)
      - bank_safe_box_id: int (required)
      - commission_rate: float (optional, default from PM)
      - commission_fixed: float (optional, default from PM)
      - fee_account_id: int (optional, default from PM)
      - settlement_date: ISO string (optional)
      - created_by: str (optional)
    """
    data = request.get_json(silent=True) or {}

    clearing_safe_box_id = data.get('clearing_safe_box_id') or data.get('from_safe_box_id')
    bank_safe_box_id = data.get('bank_safe_box_id') or data.get('to_safe_box_id')
    created_by = data.get('created_by', 'system')

    if not clearing_safe_box_id or not bank_safe_box_id:
        return jsonify({'error': 'clearing_safe_box_id and bank_safe_box_id are required'}), 400

    clearing_sb = SafeBox.query.get(clearing_safe_box_id)
    bank_sb = SafeBox.query.get(bank_safe_box_id)
    if not clearing_sb or not clearing_sb.is_active:
        return jsonify({'error': 'Clearing safe box not found or inactive'}), 404
    if not bank_sb or not bank_sb.is_active:
        return jsonify({'error': 'Bank safe box not found or inactive'}), 404
    if (clearing_sb.safe_type or '').strip().lower() != 'clearing':
        return jsonify({'error': 'Source must be a clearing safe box'}), 400
    if (bank_sb.safe_type or '').strip().lower() != 'bank':
        return jsonify({'error': 'Target must be a bank safe box'}), 400

    # Resolve commission parameters from payment method
    matched_pm = (
        PaymentMethod.query
        .filter_by(default_safe_box_id=clearing_safe_box_id, is_active=True)
        .first()
    )
    rate = float(data.get('commission_rate') if 'commission_rate' in data
                 else (getattr(matched_pm, 'commission_rate', 0.0) or 0.0) if matched_pm else 0.0)
    fixed = float(data.get('commission_fixed') if 'commission_fixed' in data
                  else (getattr(matched_pm, 'commission_fixed_amount', 0.0) or 0.0) if matched_pm else 0.0)

    fee_account_id = data.get('fee_account_id')
    if fee_account_id is None and matched_pm:
        fee_account_id = getattr(matched_pm, 'fee_expense_account_id', None)

    # Check commission_timing — if 'invoice', fee must be 0
    timing = 'invoice'
    if matched_pm:
        timing = str(getattr(matched_pm, 'commission_timing', 'invoice') or 'invoice').strip().lower()

    # Parse settlement date
    settlement_date_raw = data.get('settlement_date') or data.get('date')
    settlement_dt = datetime.now()
    if settlement_date_raw:
        try:
            if isinstance(settlement_date_raw, str) and len(settlement_date_raw) == 10:
                settlement_dt = datetime.fromisoformat(settlement_date_raw + 'T00:00:00')
            else:
                settlement_dt = datetime.fromisoformat(settlement_date_raw)
        except Exception:
            return jsonify({'error': 'invalid settlement_date'}), 400

    # Find unsettled invoice payments in this clearing safe box
    # An invoice_payment SafeBoxTransaction is "unsettled" if no clearing_settlement
    # voucher has created a corresponding 'out' transaction referencing it.
    try:
        unsettled_txs = _unsettled_invoice_payment_sbts(clearing_safe_box_id)
    except Exception as exc:
        return jsonify({'error': f'Failed to query transactions: {exc}'}), 500

    # ----------------------------------------------------------------
    # Determine which payments are still pending using the same FIFO
    # hybrid approach as the pending-transactions GET endpoint.
    # This correctly handles both per-tx and bulk settlements.
    # ----------------------------------------------------------------

    # (a) Per-tx settled IDs
    settled_ip_ids = set()
    try:
        settled_txs = (
            db.session.query(SafeBoxTransaction.notes)
            .join(Voucher, Voucher.id == SafeBoxTransaction.ref_id)
            .filter(
                SafeBoxTransaction.safe_box_id == clearing_safe_box_id,
                SafeBoxTransaction.ref_type.in_(['voucher', 'voucher_reversal']),
                Voucher.reference_type == 'clearing_settlement',
                SafeBoxTransaction.notes.isnot(None),
            )
            .all()
        )
        for (note_val,) in settled_txs:
            if note_val and note_val.startswith('per_tx:ip_'):
                try:
                    settled_ip_ids.add(int(note_val.split('per_tx:ip_')[1]))
                except Exception:
                    pass
    except Exception:
        pass

    # (b) Aggregate settled total from clearing_settlement vouchers
    aggregate_settled = 0.0
    try:
        settled_signed = func.coalesce(
            func.sum(
                case(
                    (SafeBoxTransaction.direction == 'out', SafeBoxTransaction.amount_cash),
                    else_=-SafeBoxTransaction.amount_cash,
                )
            ),
            0.0,
        )
        aggregate_settled = float(
            db.session.query(settled_signed)
            .join(Voucher, Voucher.id == SafeBoxTransaction.ref_id)
            .filter(
                SafeBoxTransaction.safe_box_id == clearing_safe_box_id,
                SafeBoxTransaction.ref_type.in_(['voucher', 'voucher_reversal']),
                Voucher.reference_type == 'clearing_settlement',
            )
            .scalar()
            or 0.0
        )
    except Exception:
        pass

    # (c) FIFO walk: consume bulk-settled amount across non-per-tx payments
    remaining_bulk_settled = max(aggregate_settled, 0.0)
    pending = []
    for tx in unsettled_txs:
        ip_id = tx.invoice_payment_id or tx.id
        if ip_id in settled_ip_ids:
            remaining_bulk_settled -= round(float(tx.amount_cash or 0.0), 2)
            continue
        tx_amount = round(float(tx.amount_cash or 0.0), 2)
        if remaining_bulk_settled >= tx_amount - 0.005:
            remaining_bulk_settled -= tx_amount
            continue
        pending.append(tx)

    if not pending:
        return jsonify({
            'success': True,
            'message': 'لا توجد معاملات معلّقة للتسوية',
            'settled_count': 0,
            'vouchers': [],
        }), 200

    # Process each transaction
    results = []
    errors = []
    for tx in pending:
        try:
            gross = round(float(tx.amount_cash or 0.0), 2)
            if gross <= 0.01:
                continue

            # Compute fee
            fee = 0.0
            if timing == 'settlement':
                fee = round((gross * rate / 100.0) + fixed, 2)

            ref_num = f"PERTX-IP{tx.invoice_payment_id or tx.id}-{settlement_dt.strftime('%Y%m%d')}"

            # Build description with invoice info
            inv_info = ''
            if tx.invoice_id:
                try:
                    inv = Invoice.query.get(tx.invoice_id)
                    if inv:
                        inv_info = f' (فاتورة {inv.invoice_number})'
                except Exception:
                    pass

            desc = (
                f'تسوية فردية: {clearing_sb.name} → {bank_sb.name}'
                f' — مبلغ {gross:.2f}{inv_info}'
            )

            result = _create_clearing_settlement_voucher(
                clearing_safe_box_id=clearing_sb.id,
                bank_safe_box_id=bank_sb.id,
                gross_amount=gross,
                fee_amount=fee,
                settlement_dt=settlement_dt,
                reference_number=ref_num,
                created_by=created_by,
                fee_account_id=fee_account_id if fee > 0 else None,
                description_override=desc,
                notes=f'per_tx:ip_{tx.invoice_payment_id or tx.id}',
                ensure_unique_reference=True,
            )

            if result.get('skipped'):
                continue

            results.append({
                'invoice_payment_id': tx.invoice_payment_id,
                'invoice_id': tx.invoice_id,
                'gross': gross,
                'fee': fee,
                'voucher_number': result.get('voucher', {}).get('voucher_number'),
            })
        except Exception as exc:
            errors.append({
                'tx_id': tx.id,
                'invoice_payment_id': tx.invoice_payment_id,
                'error': str(exc),
            })
            db.session.rollback()

    if results:
        try:
            db.session.commit()
        except Exception as exc:
            db.session.rollback()
            return jsonify({'error': f'Failed to commit: {exc}'}), 500

    return jsonify({
        'success': True,
        'settled_count': len(results),
        'settlements': results,
        'errors': errors if errors else None,
    }), 201

@clearing_bp.route('/clearing/settlements/pending-transactions', methods=['GET'])
@require_permission('vouchers.create')
def get_pending_settlement_transactions():
    """List unsettled invoice payment transactions in a clearing safe box.

    Query params:
      - clearing_safe_box_id: int (required)
    """
    clearing_safe_box_id = request.args.get('clearing_safe_box_id', type=int)
    if not clearing_safe_box_id:
        return jsonify({'error': 'clearing_safe_box_id is required'}), 400

    clearing_sb = SafeBox.query.get(clearing_safe_box_id)
    if not clearing_sb:
        return jsonify({'error': 'Safe box not found'}), 404

    try:
        # Source payments from InvoicePayment (always authoritative) rather than
        # SafeBoxTransaction, because historical SBTs may carry the wrong
        # safe_box_id (multi-payment invoice routing bug fixed Apr 2026).
        from clearing_settlement_scheduler import settleable_payments_query
        all_ips = (
            settleable_payments_query(int(clearing_safe_box_id))
            .order_by(InvoicePayment.created_at.asc())
            .all()
        )
    except Exception as exc:
        return jsonify({'error': str(exc)}), 500

    # ----------------------------------------------------------------
    # Determine which invoice-payment transactions are still pending.
    #
    # Uses SettlementLine amounts (supports partial settlements) to
    # compute per-IP remaining balance.  An IP is pending when:
    #   remaining = IP.amount - sum(SL.amount_settled) > 0
    # ----------------------------------------------------------------

    all_ip_ids = [ip.id for ip in all_ips]

    # Sum settled amount per IP from SettlementLine table.
    settled_by_ip = {}  # ip_id → total amount already settled
    try:
        settled_by_ip = get_settled_amounts(all_ip_ids)
    except Exception:
        pass

    # Also check legacy per_tx notes on Voucher (treat as fully settled).
    legacy_settled_ip_ids = set()
    try:
        clearing_account_id = getattr(clearing_sb, 'account_id', None)
        per_tx_q = (
            db.session.query(Voucher.notes)
            .filter(
                Voucher.reference_type == 'clearing_settlement',
                Voucher.notes.isnot(None),
                Voucher.notes.like('%per_tx:ip_%'),
            )
        )
        if clearing_account_id:
            per_tx_q = per_tx_q.join(
                VoucherAccountLine, VoucherAccountLine.voucher_id == Voucher.id
            ).filter(VoucherAccountLine.account_id == clearing_account_id)
        for (note_val,) in per_tx_q.distinct().all():
            if note_val and 'per_tx:ip_' in note_val:
                try:
                    legacy_settled_ip_ids.add(int(note_val.split('per_tx:ip_')[1].split()[0]))
                except Exception:
                    pass
    except Exception:
        pass

    # Build pending list: IPs with remaining unsettled balance.
    due_amount = _compute_clearing_due_amount(clearing_safe_box_id)

    # ── Transfer-out FIFO attribution ────────────────────────────────────────
    # If some voucher_out rows are transfer outflows (no SettlementLine backing),
    # we must "consume" the oldest IPs first so they don't falsely appear pending.
    #
    # net_voucher_out = voucher OUT − reversal IN  (reversals undo cancelled outs)
    # transfer_out_unaccounted = net_voucher_out − (SettlementLine + legacy)
    # This remainder is attributed FIFO-first to IPs so they are hidden from the list.
    try:
        total_voucher_out = (
            db.session.query(func.coalesce(func.sum(SafeBoxTransaction.amount_cash), 0.0))
            .filter(
                SafeBoxTransaction.safe_box_id == clearing_safe_box_id,
                SafeBoxTransaction.ref_type == 'voucher',
                SafeBoxTransaction.direction == 'out',
            )
            .scalar()
        ) or 0.0
        total_voucher_out = round(float(total_voucher_out), 2)

        # Subtract reversal-ins: they undo previously-counted voucher-outs
        total_reversal_in = (
            db.session.query(func.coalesce(func.sum(SafeBoxTransaction.amount_cash), 0.0))
            .filter(
                SafeBoxTransaction.safe_box_id == clearing_safe_box_id,
                SafeBoxTransaction.ref_type == 'voucher_reversal',
                SafeBoxTransaction.direction == 'in',
            )
            .scalar()
        ) or 0.0
        net_voucher_out = max(0.0, round(total_voucher_out - float(total_reversal_in), 2))

        # Total already covered by SettlementLine records
        sl_covered = round(sum(settled_by_ip.values()), 2)

        # Legacy-settled IPs: treated as fully covered
        legacy_covered = 0.0
        for ip in all_ips:
            if ip.id in legacy_settled_ip_ids:
                legacy_covered += float(ip.amount or 0)
        legacy_covered = round(legacy_covered, 2)

        # Unaccounted outflow = net settlement-outs that consumed IPs without SettlementLine
        transfer_out_unaccounted = max(0.0, round(net_voucher_out - sl_covered - legacy_covered, 2))

        # ── FIFO cap ─────────────────────────────────────────────────────────
        # transfer_out_unaccounted can be inflated by "ghost credits" — voucher
        # outs that settled non-IP items (e.g. direct invoice JEs from before
        # the PaymentMethod routing system was in place).  If we use the raw
        # figure, FIFO consumes genuinely-pending IPs, making them invisible.
        #
        # Correct cap:  FIFO may only consume up to:
        #   non_sl_ip_total − due_amount
        # where non_sl_ip_total = sum of remaining IP balances with no SL record.
        # That equals the IPs truly settled historically without SL,
        # leaving due_amount worth of IPs visible as pending.
        non_sl_ip_total = round(sum(
            max(0.0, round(float(ip.amount or 0), 2) - round(settled_by_ip.get(ip.id, 0.0), 2))
            for ip in all_ips
            if ip.id not in legacy_settled_ip_ids
        ), 2)
        fifo_cap = max(0.0, round(non_sl_ip_total - max(0.0, due_amount), 2))
        transfer_out_unaccounted = min(transfer_out_unaccounted, fifo_cap)
        # ─────────────────────────────────────────────────────────────────────
    except Exception:
        transfer_out_unaccounted = 0.0

    # Extra credit per IP consumed by transfer-out (FIFO applied below)
    transfer_credit_by_ip = {}  # ip_id → extra amount consumed by transfer-out
    if transfer_out_unaccounted > 0.005:
        remaining_credit = transfer_out_unaccounted
        for ip in all_ips:
            if ip.id in legacy_settled_ip_ids or remaining_credit <= 0.005:
                break
            ip_amount = round(float(ip.amount or 0.0), 2)
            already_settled = round(settled_by_ip.get(ip.id, 0.0), 2)
            available = round(ip_amount - already_settled, 2)
            if available <= 0.005:
                continue
            consumed = min(available, remaining_credit)
            transfer_credit_by_ip[ip.id] = round(consumed, 2)
            remaining_credit = round(remaining_credit - consumed, 2)
    # ────────────────────────────────────────────────────────────────────────
    # Compute how much transfer_out_unaccounted remains after IP FIFO attribution.
    # This remainder covers safe_transfer-in items (inter-safe corrections).
    transfer_out_remaining_after_ips = max(0.0, round(
        transfer_out_unaccounted - sum(transfer_credit_by_ip.values()), 2
    ))

    pending = []
    for ip in all_ips:  # already ordered by created_at asc
        if ip.id in legacy_settled_ip_ids:
            continue
        ip_amount = round(float(ip.amount or 0.0), 2)
        settled = round(settled_by_ip.get(ip.id, 0.0) + transfer_credit_by_ip.get(ip.id, 0.0), 2)
        remaining = round(ip_amount - settled, 2)
        if remaining <= 0.005:
            continue
        invoice_number = None
        invoice_id = ip.invoice_id
        if invoice_id:
            try:
                inv = Invoice.query.get(invoice_id)
                if inv:
                    invoice_number = inv.invoice_number
            except Exception:
                pass
        pending.append({
            'tx_id': ip.id,
            'invoice_payment_id': ip.id,
            'invoice_id': invoice_id,
            'invoice_number': invoice_number,
            'amount': remaining,
            'date': ip.created_at.isoformat() if ip.created_at else None,
            'type': 'invoice_payment',
        })

    # tx_count_for_fee: number of pending invoice-payment transactions only.
    # Transfer-in items below are NOT counted since they don't carry a
    # per-transaction fee in the normal commission model.
    tx_count_for_fee = len(pending)

    # Also include safe-box transfer-in items as pending.
    # These arise when an operator corrects a routing error by transferring
    # from one clearing safe to another (e.g. تابي → تمارا).  The destination
    # safe receives an SBT in/voucher with no invoice_payment_id.
    #
    # Reversals: a voucher_reversal SBT shares the same ref_id as the original
    # transfer SBT it cancels.  We match by ref_id to exclude fully-reversed
    # transfers rather than proportionally reducing all of them.
    try:
        transfer_in_sbts = (
            SafeBoxTransaction.query
            .filter(
                SafeBoxTransaction.safe_box_id == clearing_safe_box_id,
                SafeBoxTransaction.ref_type == 'voucher',
                SafeBoxTransaction.direction == 'in',
                SafeBoxTransaction.invoice_payment_id.is_(None),
            )
            .order_by(SafeBoxTransaction.created_at.asc())
            .all()
        )

        if transfer_in_sbts:
            # Build a set of ref_ids that have been reversed (voucher_reversal out, no IP).
            # A ref_id in this set means the transfer was cancelled and should be excluded.
            reversal_out_sbts = (
                SafeBoxTransaction.query
                .filter(
                    SafeBoxTransaction.safe_box_id == clearing_safe_box_id,
                    SafeBoxTransaction.ref_type == 'voucher_reversal',
                    SafeBoxTransaction.direction == 'out',
                    SafeBoxTransaction.invoice_payment_id.is_(None),
                )
                .all()
            )
            reversed_ref_ids = set()
            reversal_by_ref = {}  # ref_id → total reversed amount
            for r in reversal_out_sbts:
                rid = r.ref_id
                if rid is not None:
                    reversed_ref_ids.add(rid)
                    reversal_by_ref[rid] = reversal_by_ref.get(rid, 0.0) + float(r.amount_cash or 0)

            remaining_transfer_credit = transfer_out_remaining_after_ips
            for tx in transfer_in_sbts:
                tx_amount = float(tx.amount_cash or 0)
                if tx.ref_id is not None and tx.ref_id in reversed_ref_ids:
                    # Partially or fully reversed: compute net remaining
                    reversed_amt = reversal_by_ref.get(tx.ref_id, tx_amount)
                    tx_remaining = max(0.0, round(tx_amount - reversed_amt, 2))
                else:
                    tx_remaining = round(tx_amount, 2)

                # Apply unaccounted outflow credit FIFO to safe_transfer items too
                if remaining_transfer_credit > 0.005 and tx_remaining > 0.005:
                    consumed = min(tx_remaining, remaining_transfer_credit)
                    tx_remaining = round(tx_remaining - consumed, 2)
                    remaining_transfer_credit = round(remaining_transfer_credit - consumed, 2)

                if tx_remaining <= 0.005:
                    continue
                pending.append({
                    'tx_id': f'transfer_{tx.id}',
                    'invoice_payment_id': None,
                    'invoice_id': None,
                    'invoice_number': None,
                    'amount': tx_remaining,
                    'date': tx.created_at.isoformat() if tx.created_at else None,
                    'type': 'safe_transfer',
                    'ref_id': tx.ref_id,
                    'note': 'تحويل من خزنة مقاصة أخرى',
                })
    except Exception:
        pass

    return jsonify({
        'clearing_safe_box_id': clearing_safe_box_id,
        'pending_count': len(pending),
        'due_amount': round(due_amount, 2),
        'tx_count_for_fee': tx_count_for_fee,
        'transactions': pending,
    }), 200

@clearing_bp.route('/clearing/settlements/auto-run', methods=['POST'])
@require_permission('vouchers.create')
def run_auto_clearing_settlements_now():
    """Run the clearing auto-settlement scheduler immediately.

    This is intended for manual operational triggering and verification.
    The actual settlement logic remains centralized in the scheduler.
    """
    try:
        from clearing_settlement_scheduler import get_clearing_settlement_scheduler

        scheduler = get_clearing_settlement_scheduler(current_app._get_current_object())
        diag = scheduler.process_due_settlements()

        settled_count = diag.get('settled_count', 0)
        per_tx_count = diag.get('per_tx_settled_count', 0)
        enabled_methods = diag.get('enabled_methods', 0)
        skipped = diag.get('skipped', [])

        total_settled = settled_count + per_tx_count
        if total_settled > 0:
            message = f'تم إنشاء {total_settled} سند تسوية تلقائية'
        elif enabled_methods == 0:
            message = 'لا توجد وسائل دفع مفعّلة للتسوية التلقائية'
        else:
            message = 'لا توجد مستحقات مؤهلة للتسوية الآن'

        return jsonify({
            'success': True,
            'enabled_methods': int(enabled_methods),
            'settled_count': settled_count,
            'per_tx_settled_count': per_tx_count,
            'message': message,
            'skipped': skipped,
        }), 200
    except Exception as exc:
        db.session.rollback()
        return jsonify({
            'success': False,
            'error': f'failed_to_run_auto_settlement: {exc}',
        }), 500

@require_permission('vouchers.create')
def create_bnpl_settlement():
    """Create a BNPL settlement voucher and update balances.

    Best practice flow:
    - Credit: BNPL receivable (gross)
    - Debit: Bank (net)
    - Debit: BNPL commission expense (fee)

    Body:
      - bnpl_safe_box_id: int (Tabby/Tamara safe box)
      - bank_safe_box_id: int (bank safe box)
      - gross_amount: float
      - fee_amount: float (optional, default 0)
      - settlement_date: ISO datetime/date (optional)
      - reference_number: str (optional)
      - created_by: str (optional)
      - fee_account_id: int (optional; if omitted uses 5113/5114 based on provider)
      - provider: 'tabby'|'tamara' (optional; if omitted inferred from BNPL account)
    """
    data = request.get_json(silent=True) or {}

    bnpl_safe_box_id = data.get('bnpl_safe_box_id') or data.get('from_safe_box_id')
    bank_safe_box_id = data.get('bank_safe_box_id') or data.get('to_safe_box_id')
    created_by = data.get('created_by', 'system')
    reference_number = data.get('reference_number')
    provider = (data.get('provider') or '').strip().lower() or None

    try:
        gross_amount = float(data.get('gross_amount') or data.get('amount') or 0.0)
        fee_amount = float(data.get('fee_amount') or data.get('fee') or 0.0)
    except (TypeError, ValueError):
        return jsonify({'error': 'invalid gross_amount/fee_amount'}), 400

    if not bnpl_safe_box_id or not bank_safe_box_id:
        return jsonify({'error': 'bnpl_safe_box_id and bank_safe_box_id are required'}), 400

    if gross_amount <= 0:
        return jsonify({'error': 'gross_amount must be > 0'}), 400

    if fee_amount < 0:
        return jsonify({'error': 'fee_amount must be >= 0'}), 400

    net_amount = round(gross_amount - fee_amount, 2)
    if net_amount < 0:
        return jsonify({'error': 'fee_amount cannot exceed gross_amount'}), 400

    # Parse settlement date
    settlement_date_raw = data.get('settlement_date') or data.get('date')
    settlement_dt = datetime.now()
    if settlement_date_raw:
        try:
            # Accept YYYY-MM-DD or full ISO
            if isinstance(settlement_date_raw, str) and len(settlement_date_raw) == 10:
                settlement_dt = datetime.fromisoformat(settlement_date_raw + 'T00:00:00')
            else:
                settlement_dt = datetime.fromisoformat(settlement_date_raw)
        except Exception:
            return jsonify({'error': 'invalid settlement_date'}), 400

    bnpl_safe_box = SafeBox.query.get(bnpl_safe_box_id)
    if not bnpl_safe_box or not bnpl_safe_box.is_active:
        return jsonify({'error': 'BNPL safe box not found or inactive'}), 404

    bank_safe_box = SafeBox.query.get(bank_safe_box_id)
    if not bank_safe_box or not bank_safe_box.is_active:
        return jsonify({'error': 'Bank safe box not found or inactive'}), 404

    # BNPL receivable safe can be represented as bank (legacy) or clearing (preferred)
    if (bnpl_safe_box.safe_type or '').strip().lower() not in ('bank', 'clearing'):
        return jsonify({'error': 'BNPL safe box must be of type bank or clearing'}), 400

    if (bank_safe_box.safe_type or '').strip().lower() != 'bank':
        return jsonify({'error': 'bank_safe_box must be of type bank'}), 400

    bnpl_account = bnpl_safe_box.account
    bank_account = bank_safe_box.account
    if not bnpl_account or not bank_account:
        return jsonify({'error': 'Safe box must be linked to an account'}), 400

    # Infer provider if missing
    if not provider:
        bank_name = (getattr(bnpl_account, 'bank_name', None) or getattr(bnpl_safe_box, 'bank_name', None) or '').lower()
        account_name = (getattr(bnpl_account, 'name', '') or '').lower()
        if 'tabby' in bank_name or 'تابي' in bank_name or 'tabby' in account_name or 'تابي' in account_name:
            provider = 'tabby'
        elif 'tamara' in bank_name or 'تمارا' in bank_name or 'tamara' in account_name or 'تمارا' in account_name:
            provider = 'tamara'

    # Resolve fee account
    fee_account = None
    fee_account_id = data.get('fee_account_id')
    if fee_amount > 0:
        if fee_account_id:
            fee_account = Account.query.get(fee_account_id)
            if not fee_account:
                return jsonify({'error': 'fee_account_id not found'}), 404
        else:
            if provider == 'tabby':
                fee_account = Account.query.filter_by(account_number='5113').first()
            elif provider == 'tamara':
                fee_account = Account.query.filter_by(account_number='5114').first()

        if not fee_account:
            return jsonify({
                'error': 'fee_account is required for fee_amount > 0',
                'hint': 'Provide fee_account_id or ensure accounts 5113/5114 exist'
            }), 400

    # Balance check: prevent settling more than receivable tracked in system
    bnpl_balance = float(getattr(bnpl_account, 'balance_cash', 0.0) or 0.0)
    if bnpl_balance < gross_amount:
        return jsonify({
            'error': 'BNPL balance is insufficient for settlement',
            'bnpl_balance': round(bnpl_balance, 2),
            'gross_amount': round(gross_amount, 2)
        }), 400

    # Create adjustment voucher + lines and a journal entry for audit.
    try:
        voucher_number = generate_voucher_number('adjustment', voucher_date=settlement_dt)

        provider_label = 'تابي' if provider == 'tabby' else ('تمارا' if provider == 'tamara' else 'BNPL')
        description = (
            f'تسوية {provider_label}: {bnpl_safe_box.name} → {bank_safe_box.name} '
            f'(إجمالي {gross_amount:.2f}، عمولة {fee_amount:.2f}، صافي {net_amount:.2f})'
        )

        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='adjustment',
            date=settlement_dt,
            description=description,
            reference_type='bnpl_settlement',
            reference_number=reference_number,
            notes=(data.get('notes') or '').strip() or None,
            created_by=created_by,
            status='approved',
            approved_by=created_by,
            approved_at=datetime.now(),
            amount_cash=round(gross_amount, 2),
            amount_gold=0.0,
        )
        db.session.add(voucher)
        db.session.flush()

        lines = []
        if net_amount > 0:
            lines.append(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=bank_account.id,
                line_type='debit',
                amount_type='cash',
                amount=round(net_amount, 2),
                description=f'إيداع صافي تسوية {provider_label} إلى {bank_safe_box.name}',
            ))

        if fee_amount > 0:
            lines.append(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=fee_account.id,
                line_type='debit',
                amount_type='cash',
                amount=round(fee_amount, 2),
                description=f'عمولة {provider_label}',
            ))

        lines.append(VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=bnpl_account.id,
            line_type='credit',
            amount_type='cash',
            amount=round(gross_amount, 2),
            description=f'إقفال مستحقات {provider_label}',
        ))

        for line in lines:
            db.session.add(line)

        db.session.flush()

        # Create journal entry for audit linkage (does not post balances)
        journal_entry = create_journal_entry_from_voucher(voucher)
        if journal_entry:
            voucher.journal_entry_id = journal_entry.id

        # Update balances immediately (system tracks balances outside posting)
        bnpl_account.update_balance(cash_amount=-gross_amount)
        bank_account.update_balance(cash_amount=net_amount)
        if fee_account:
            fee_account.update_balance(cash_amount=fee_amount)

        # Ledger: create SafeBoxTransaction rows for the safe-box-targeting lines.
        _append_safe_transactions_for_voucher(voucher, created_by=created_by)

        db.session.commit()

        return jsonify({
            'success': True,
            'voucher': voucher.to_dict(),
            'balances': {
                'bnpl_account_cash': round(float(getattr(bnpl_account, 'balance_cash', 0.0) or 0.0), 2),
                'bank_account_cash': round(float(getattr(bank_account, 'balance_cash', 0.0) or 0.0), 2),
                **({'fee_account_cash': round(float(getattr(fee_account, 'balance_cash', 0.0) or 0.0), 2)} if fee_account else {}),
            }
        }), 201

    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'Failed to create BNPL settlement: {str(exc)}'}), 500

@clearing_bp.route('/weight-closing/cash-settlement', methods=['POST'])
@require_permission('journal.post')
def create_weight_closing_cash_settlement():
    """Consume open weight-closing orders using a cash amount and live gold price."""
    data = request.get_json(silent=True) or {}
    cash_amount = _coerce_float(data.get('cash_amount'))
    if cash_amount <= 0:
        return jsonify({'error': 'cash_amount must be greater than zero'}), 400

    execution_price = _coerce_float(data.get('price_per_gram'), None)
    if execution_price is None or execution_price <= 0:
        price_snapshot = get_current_gold_price()
        execution_price = price_snapshot.get('price_per_gram_24k', 0.0)

    if execution_price <= 0:
        return jsonify({'error': 'Unable to determine gold price per gram'}), 400

    summary = _auto_consume_weight_closing(
        data.get('source_invoice_id'),
        price_per_gram=execution_price,
        cash_amount=cash_amount,
        execution_type=data.get('execution_type', 'expense'),
        journal_entry_id=data.get('journal_entry_id'),
        notes=data.get('notes'),
    )
    summary['price_per_gram'] = execution_price
    return jsonify(summary)

@clearing_bp.route('/weight-closing/execute-profile', methods=['POST'])
@require_permission('journal.post')
def execute_weight_closing_profile():
    data = request.get_json(silent=True) or {}
    profile_key = data.get('profile_key')
    if not profile_key:
        return jsonify({'error': 'profile_key مطلوب'}), 400

    ensure_weight_closing_support_accounts()

    try:
        profile = resolve_weight_profile(profile_key)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    financial_account = profile.get('financial_account')
    if not financial_account:
        return jsonify({'error': 'الحساب المالي للبروفايل غير متوفر'}), 400

    settings = _load_weight_closing_settings()

    def _resolve_cash_account_from_safebox_id(safe_box_id: int):
        if not safe_box_id or safe_box_id <= 0:
            return None
        safe_box = SafeBox.query.get(int(safe_box_id))
        if not safe_box or not safe_box.is_active:
            return None
        if (safe_box.safe_type or '').strip().lower() not in {'cash', 'bank'}:
            return None
        return Account.query.get(safe_box.account_id) if safe_box.account_id else None

    # SafeBox selection chain:
    # 1) explicit override in request payload
    # 2) supplier.default_safe_box_id (when supplier_id provided)
    # 3) settings.weight_closing_settings.cash_safe_box_id
    # 4) legacy settings.cash_account_id (id or account_number-like)
    supplier = None
    supplier_id = data.get('supplier_id')
    try:
        supplier_id_int = int(supplier_id) if supplier_id not in (None, '', False) else None
    except Exception:
        supplier_id_int = None
    if supplier_id_int:
        supplier = Supplier.query.get(supplier_id_int)

    override_safe_box_id = data.get('cash_safe_box_id')
    try:
        override_safe_box_id_int = int(override_safe_box_id) if override_safe_box_id not in (None, '', False) else None
    except Exception:
        override_safe_box_id_int = None

    chosen_cash_safe_box_id = None
    cash_account = None
    if override_safe_box_id_int:
        cash_account = _resolve_cash_account_from_safebox_id(override_safe_box_id_int)
        if not cash_account:
            return jsonify({
                'error': 'الخزينة النقدية المختارة غير صالحة',
                'details': f"cash_safe_box_id={override_safe_box_id_int}",
            }), 400
        chosen_cash_safe_box_id = override_safe_box_id_int
    else:
        supplier_safe_box_id = getattr(supplier, 'default_safe_box_id', None) if supplier else None
        if supplier_safe_box_id:
            cash_account = _resolve_cash_account_from_safebox_id(int(supplier_safe_box_id))
            if cash_account:
                chosen_cash_safe_box_id = int(supplier_safe_box_id)

        if not cash_account:
            settings_safe_box_id = settings.get('cash_safe_box_id')
            if settings_safe_box_id:
                cash_account = _resolve_cash_account_from_safebox_id(int(settings_safe_box_id))
                if cash_account:
                    chosen_cash_safe_box_id = int(settings_safe_box_id)

        if not cash_account:
            cash_account_setting = settings.get('cash_account_id', 1100)
            cash_account = _resolve_account_from_id_or_number(cash_account_setting)

    if not cash_account:
        return jsonify({
            'error': 'تعذر تحديد حساب الصندوق/البنك للتسوية',
            'details': {
                'supplier_id': supplier_id_int,
                'supplier_default_safe_box_id': getattr(supplier, 'default_safe_box_id', None) if supplier else None,
                'settings_cash_safe_box_id': settings.get('cash_safe_box_id'),
                'cash_account_id': settings.get('cash_account_id', 1100),
            },
        }), 400

    price_per_gram = _coerce_float(data.get('price_per_gram'), None)
    price_strategy = profile['meta'].get('price_strategy', 'manual')
    if price_strategy in ('live_or_manual', 'live_only'):
        if price_per_gram is None or price_per_gram <= 0:
            snapshot = get_current_gold_price()
            price_per_gram = snapshot.get('price_per_gram_24k', 0.0)
    if price_per_gram is None or price_per_gram <= 0:
        return jsonify({'error': 'price_per_gram غير صالح'}), 400

    cash_amount = _coerce_float(data.get('cash_amount'))
    weight_main = _coerce_float(data.get('weight_main_karat'))
    if weight_main <= 0 and data.get('weight_grams'):
        karat = int(data.get('karat') or get_main_karat() or 21)
        weight_main = convert_to_main_karat(_coerce_float(data.get('weight_grams')), karat)

    if cash_amount <= 0 and weight_main > 0:
        grams_24k = convert_from_main_karat(weight_main, 24)
        cash_amount = round(grams_24k * price_per_gram, 2)

    if weight_main <= 0 and cash_amount > 0 and price_per_gram > 0:
        grams_24k = cash_amount / price_per_gram
        weight_main = convert_to_main_karat(grams_24k, 24)

    if profile['meta'].get('requires_cash_amount') and cash_amount <= 0:
        return jsonify({'error': 'هذا البروفايل يتطلب cash_amount أكبر من صفر'}), 400
    if profile['meta'].get('requires_weight') and weight_main <= 0:
        return jsonify({'error': 'هذا البروفايل يتطلب إدخال وزن'}), 400

    now = datetime.now()
    description = data.get('notes') or profile['meta'].get('display_name') or profile_key
    journal_entry = JournalEntry(
        entry_number=_generate_journal_entry_number('WXP'),
        date=now,
        description=f'تنفيذ بروفايل {profile_key}: {description}',
        reference_type='weight_profile',
        reference_id=None,
        is_posted=True,
        posted_at=now,
        posted_by='system',
    )
    db.session.add(journal_entry)
    db.session.flush()

    if cash_amount > 0:
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=financial_account.id,
            cash_debit=cash_amount,
            description=description,
        )
        create_dual_journal_entry(
            journal_entry_id=journal_entry.id,
            account_id=cash_account.id,
            cash_credit=cash_amount,
            description=description,
        )

    memo_debit_account = Account.query.get(financial_account.memo_account_id) if financial_account.memo_account_id else None
    default_memo_cash_account = Account.query.filter_by(account_number='71100').first()
    memo_credit_account = default_memo_cash_account
    if memo_debit_account and memo_credit_account and weight_main > 0:
        _record_memo_weight_transfer(
            journal_entry.id,
            debit_account_id=memo_debit_account.id,
            credit_account_id=memo_credit_account.id,
            weight_main_karat=weight_main,
        )

    verify_dual_balance(journal_entry.id)

    consumption = _auto_consume_weight_closing(
        weight_override=weight_main if weight_main > 0 else None,
        price_per_gram=price_per_gram,
        cash_amount=cash_amount,
        execution_type=profile['meta'].get('execution_type', 'expense'),
        journal_entry_id=journal_entry.id,
        notes=description,
    )
    consumption['price_per_gram'] = price_per_gram

    db.session.commit()

    return jsonify(
        {
            'profile': {
                'key': profile_key,
                'display_name': profile['meta'].get('display_name', profile_key),
            },
            'cash_safe_box_id': chosen_cash_safe_box_id,
            'cash_amount': cash_amount,
            'weight_main_karat': weight_main,
            'price_per_gram': price_per_gram,
            'journal_entry': {
                'id': journal_entry.id,
                'entry_number': journal_entry.entry_number,
                'date': journal_entry.date.isoformat(),
            },
            'weight_consumption': consumption,
        }
    )

