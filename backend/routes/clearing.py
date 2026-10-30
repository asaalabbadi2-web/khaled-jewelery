"""Clearing domain routes — clearing_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, date, timedelta

from flask import Blueprint, current_app, g, jsonify, request
from sqlalchemy import func, and_
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    Invoice,
    InvoicePayment,
    PaymentMethod,
    SafeBox,
    SafeBoxTransaction,
    Settings,
    SettlementLine,
    Voucher,
    VoucherAccountLine,
)

from auth_decorators import require_permission

from services.live_balances import live_balances_by_account_ids

from accounting.voucher_engine import (
    generate_voucher_number,
    post_entry_of_approved_voucher,
    _append_safe_transactions_for_voucher,
)
from accounting.mappings import get_account_id_for_mapping
from settlement_state_service import get_settled_amounts
from allocation_service import AllocationService

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
    # Through the ONE settleable rule. This used to select every InvoicePayment
    # of the box by payment method alone, so a rejected invoice's payment — never
    # settled, because the scheduler and the pending list already excluded it —
    # sat here forever as "pending". Measured on the 28 Sep production snapshot:
    # due shown 5,940.00, due real 3,790.00, difference 2,150.00 = invoice 3123's
    # Mada payment exactly. fe8ffc6 unified three readers and missed this fourth
    # one; TestNoFifthSettleableReader now stops the next.
    from clearing_settlement_scheduler import settleable_payments_query
    all_ip_ids: list[int] = [
        ip.id for ip in settleable_payments_query(safe_box_id).all()
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

def commission_vat(fee_amount) -> float:
    """VAT on a settlement's commission: the commission is entered net of VAT,
    and its VAT is the settings' rate (0 when tax is off). The one computation:
    the settlement voucher, and the net a flexible plan's minimum is measured
    against (services/settlement_schedule.py, ADR-037)."""
    fee_amount = float(fee_amount or 0.0)
    if fee_amount <= 0:
        return 0.0
    try:
        row = Settings.query.first()
    except Exception:
        row = None
    tax_enabled = bool(getattr(row, 'tax_enabled', True)) if row else True
    if not tax_enabled:
        return 0.0
    try:
        rate = float(getattr(row, 'tax_rate', 0.15) if row else 0.15)
    except (TypeError, ValueError):
        rate = 0.15
    if rate > 1.0:
        rate = rate / 100.0
    return round(fee_amount * abs(rate), 2)


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

    fee_vat = commission_vat(fee_amount) if fee_is_net else 0.0

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
        # A cancelled settlement holds no batch: its payments are unsettled
        # again and are settled again (31 Oct 2026 -- the batch was skipped for ever).
        prior_vouchers_same_reference = Voucher.query.filter(
            Voucher.reference_type == 'clearing_settlement',
            Voucher.reference_number == reference_number,
            Voucher.status != 'cancelled',
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
            # The method's own fee account -- its link. No account is guessed by
            # number (5100/5110/5113 did not exist on production; CHART-002).
            if matched_pm and getattr(matched_pm, 'fee_expense_account_id', None):
                fee_account_id = matched_pm.fee_expense_account_id

        if not fee_account_id:
            raise ValueError('fee_account_id_required')
        fee_account = Account.query.get(fee_account_id)
        if not fee_account:
            raise ValueError('not_found:fee_account')

    commission_vat_account = None
    from services.vat_policy import non_recoverable_account_id, policy_on
    _settled_on = settlement_dt or datetime.now()
    _vat_day = _settled_on.date() if isinstance(_settled_on, datetime) else _settled_on
    if fee_vat > 0 and not policy_on(_vat_day).input_vat_recoverable:
        # Not recovered (ADR-043 rule 1): a commission enters no stock.
        commission_vat_account_id = non_recoverable_account_id()
    if fee_vat > 0:
        # Prefer a dedicated account for VAT on commissions; if not configured,
        # fall back to the generic VAT receivable (input VAT) account.
        commission_vat_account_id = (
            commission_vat_account_id
            or get_account_id_for_mapping('بيع', 'commission_vat')
        )
        if commission_vat_account_id:
            commission_vat_account = Account.query.get(commission_vat_account_id)

        if not commission_vat_account:
            fallback_vat_id = (
                get_account_id_for_mapping('بيع', 'vat_receivable')
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

    # Born approved, born posted (APPROVED-ENTRY-001): raises if no entry.
    post_entry_of_approved_voucher(voucher, posted_by=created_by)

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
    return _settle_from_request(preview=False)


@clearing_bp.route('/clearing/settlements/preview', methods=['POST'])
@require_permission('vouchers.create')
def preview_clearing_settlement():
    """The voucher a settlement would post, not posted (ADR-050).

    The same body as POST /clearing/settlements, through the same function:
    the voucher is built, its lines read, and all of it rolled back. The
    screen showed a summary it computed itself -- 15% VAT until the settings
    came, and the receivable VAT account where ADR-043 posts the commission's
    VAT to the non-recoverable one; now it shows what will be posted.
    """
    return _settle_from_request(preview=True)


def _settle_from_request(*, preview: bool):
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
        if preview:
            return _preview_of(result)
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

        return jsonify({'error': 'validation_error', 'message': msg}), 400

    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'Failed to create clearing settlement: {str(exc)}'}), 500

def _preview_of(result):
    """The lines of the voucher just built in this request, then nothing of
    it kept: the session is rolled back before the answer leaves."""
    try:
        voucher_id = (result.get('voucher') or {}).get('id')
        rows = (
            db.session.query(VoucherAccountLine, Account)
            .join(Account, Account.id == VoucherAccountLine.account_id)
            .filter(VoucherAccountLine.voucher_id == voucher_id)
            .order_by(VoucherAccountLine.id.asc())
            .all()
        ) if voucher_id else []
        lines = [
            {
                'account_id': account.id,
                'account_number': account.account_number,
                'account_name': account.name,
                'side': line.line_type,
                'amount': round(float(line.amount or 0.0), 2),
                'description': line.description,
            }
            for line, account in rows
        ]
    finally:
        db.session.rollback()
        db.session.info.pop('_voucher_number_seq_cache', None)

    debit = round(sum(l['amount'] for l in lines if l['side'] == 'debit'), 2)
    credit = round(sum(l['amount'] for l in lines if l['side'] == 'credit'), 2)
    return jsonify({
        'preview': True,
        'lines': lines,
        'debit_total': debit,
        'credit_total': credit,
        'balanced': abs(debit - credit) < 0.005,
        'skipped': bool(result.get('skipped')),
    }), 200


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
        # Whose payment it is: the monitor matches a payment to the bank's
        # statement by the customer as much as by the invoice (ADR-050).
        customer_name = None
        invoice_id = ip.invoice_id
        if invoice_id:
            try:
                inv = Invoice.query.get(invoice_id)
                if inv:
                    invoice_number = inv.invoice_number
                    customer_name = inv.customer.name if inv.customer else None
            except Exception:
                pass
        pending.append({
            'tx_id': ip.id,
            'invoice_payment_id': ip.id,
            'invoice_id': invoice_id,
            'invoice_number': invoice_number,
            'customer_name': customer_name,
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
        enabled_methods = diag.get('enabled_methods', 0)
        skipped = diag.get('skipped', [])

        if settled_count > 0:
            message = f'تم إنشاء {settled_count} سند تسوية تلقائية'
        elif enabled_methods == 0:
            message = 'لا توجد وسائل دفع مفعّلة للتسوية التلقائية'
        else:
            message = 'لا توجد مستحقات مؤهلة للتسوية الآن'

        return jsonify({
            'success': True,
            'enabled_methods': int(enabled_methods),
            'settled_count': settled_count,
            'message': message,
            'skipped': skipped,
        }), 200
    except Exception as exc:
        db.session.rollback()
        return jsonify({
            'success': False,
            'error': f'failed_to_run_auto_settlement: {exc}',
        }), 500

# create_bnpl_settlement (POST /bnpl/settlements) is gone (21 Oct 2026): the
# routes' split into files (023253327, Jul 2026) carried it over without its
# route, so nothing reached it since -- and Tabby and Tamara are clearing safes,
# settled by the one clearing settlement (25 automatic, 8 manual on the 17 Oct
# copy). A second way to settle them would be a parallel system.

# POST /weight-closing/execute-profile went with the profiles (ADR-048 phase 3c): a
# marked expense closes its riyals in the weight position from its own voucher.
