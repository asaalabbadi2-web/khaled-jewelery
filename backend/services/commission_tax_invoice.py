"""A commission's VAT waits for its monthly tax invoice (ADR-101).

The owner, 25 Nov 2026 («الفواتير الضريبية»): an installment company issues
one tax invoice a month for the commissions of the orders made in it, and the
input VAT stands on that invoice. The settlement booked the commission's VAT
on the day its deposit was due, so the return claimed VAT the company had not
invoiced yet -- 432.25 of October's 898.26 -- and a late-September order's
twice (September's invoices were filed in Q3).

For a method set to issue them (its `tax_invoice_from`, POLICY, the owner's),
from that month:
  - the commission's VAT of a settlement, and of a deposit's difference, waits
    on the method's own pending account, beside the input VAT and outside the
    return (`commission_vat_account_on`, the one reading);
  - the month's invoice, entered, is claimed on its date: its VAT moves from
    the pending account to input VAT by its own voucher;
  - what the pending account then holds beyond what still waits -- the VAT of
    the settled orders of the months not yet invoiced, a deposit's difference
    shared by what it confirmed -- is the companies' rounding and goes to the
    commission. The bank is never touched; the next invoice re-anchors it.
  - cancelling the invoice's voucher undoes it: the month waits again.

Refused: a method without them, a month before them, a month invoiced, an
invoice dated before its month's last day or after today, no number, a VAT number
not 15 digits 3 first and last, a VAT not the rate's share of its fee beyond
VAT_ROUNDING_ALLOWED. No company's name decides anything here.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Optional

from sqlalchemy import func

from models import (
    Account,
    ClearingDeposit,
    ClearingDepositSettlement,
    CommissionTaxInvoice,
    Invoice,
    InvoicePayment,
    JournalEntry,
    JournalEntryLine,
    PaymentMethod,
    SettlementLine,
    Voucher,
    VoucherAccountLine,
    db,
)

REFERENCE_TYPE = 'commission_invoice'      # voucher.reference_type is 20 long
# The VAT a company prints may differ from its rate of the fee by its own
# rounding (Tamara: «Due to rounding up, there might be a slight discrepancy
# on the total VAT amount»); beyond this it is a mistyped figure. LAW.
VAT_ROUNDING_ALLOWED = 1.00
CENT = 0.005


class TaxInvoiceRefused(ValueError):
    def __init__(self, code: str, message: str, **detail):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


def month_start(day) -> date:
    return date(day.year, day.month, 1)


def next_month(month: date) -> date:
    return date(month.year + (month.month == 12), month.month % 12 + 1, 1)


def parse_month(raw) -> date:
    try:
        year, month = str(raw or '').strip()[:7].split('-')
        return date(int(year), int(month), 1)
    except (TypeError, ValueError):
        raise TaxInvoiceRefused('invalid_month', 'الشهر غير صالح (YYYY-MM)')


def waits_for_invoice(pm: Optional[PaymentMethod], day) -> bool:
    """Whether a commission's VAT of *pm* booked on *day* waits for its tax
    invoice: the method issues them from a month not after *day*, and input
    VAT is recovered that day (not recovered, it is an expense -- no claim
    waits)."""
    from services.vat_policy import policy_on
    start = getattr(pm, 'tax_invoice_from', None) if pm is not None else None
    if start is None:
        return False
    day = day.date() if isinstance(day, datetime) else day
    return day >= month_start(start) and policy_on(day).input_vat_recoverable


def pending_account(pm: PaymentMethod, claim: Account) -> Account:
    """The method's pending account -- made once, beside *claim* (the input
    VAT it waits to become), with its weight twin where the group has one."""
    from account_number_generator import get_next_account_number
    from employee_account_helpers import ensure_memo_for_account
    if pm.commission_vat_pending_account_id:
        return db.session.get(Account, pm.commission_vat_pending_account_id)
    parent = db.session.get(Account, claim.parent_id) if claim.parent_id else None
    if parent is None:
        raise ValueError('commission_vat_parent_missing')
    account = Account(account_number=str(get_next_account_number(str(parent.account_number), use_spacing=False)),
                      name=f'ضريبة عمولات {pm.name} بانتظار الفاتورة الضريبية', type='Asset',
                      transaction_type='cash', tracks_weight=False, parent_id=parent.id)
    db.session.add(account)
    db.session.flush()
    if parent.memo_account_id:
        ensure_memo_for_account(account)
    pm.commission_vat_pending_account_id = account.id
    db.session.flush()
    return account


def _balance(account_id: Optional[int]) -> float:
    from accounting.balances import counted_line_filters
    if not account_id:
        return 0.0
    value = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit), 0.0))
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters(), JournalEntryLine.account_id == account_id).scalar())
    return round(float(value or 0.0), 2)


def pending_vat(pm: PaymentMethod) -> float:
    return _balance(pm.commission_vat_pending_account_id)


def _payments(pm: PaymentMethod, start: Optional[date] = None, end: Optional[date] = None) -> list:
    """(payment, its order's day) of *pm*'s settleable payments -- the one rule
    -- whose order is dated in [start, end)."""
    from clearing_settlement_scheduler import settleable_payments_query
    if not pm.default_safe_box_id:
        return []
    q = (settleable_payments_query(pm.default_safe_box_id)
         .filter(InvoicePayment.payment_method_id == pm.id)
         .with_entities(InvoicePayment, Invoice.date))
    if start is not None:
        q = q.filter(Invoice.date >= datetime.combine(start, time.min))
    if end is not None:
        q = q.filter(Invoice.date < datetime.combine(end, time.min))
    return [(ip, day.date() if isinstance(day, datetime) else day) for ip, day in q.all()]


def _charge(pm: PaymentMethod, ip: InvoicePayment) -> tuple:
    """(commission, VAT) of one payment by the one computation, at the rate it was kept at."""
    from accounting.payment_commission import payment_commission, per_order
    rate = float(ip.commission_rate) if per_order(pm) and ip.commission_rate is not None else None
    c = payment_commission(pm, float(ip.amount or 0.0), installments=ip.installments, rate=rate, required=False)
    return Decimal(str(c['commission_amount'])), Decimal(str(c['commission_vat']))


def _settlement_vouchers(pm: PaymentMethod, start: date, end: date) -> int:
    if not pm.default_safe_box_id:
        return 0
    return (Voucher.query.filter(Voucher.reference_type == 'clearing_settlement',
                                 Voucher.reference_id == pm.default_safe_box_id,
                                 Voucher.status == 'approved',
                                 Voucher.date >= datetime.combine(start, time.min),
                                 Voucher.date < datetime.combine(end, time.min)).count())


def computed(pm: PaymentMethod, month: date) -> dict:
    """What the month's orders come to by the one computation, each at its
    kept rate, and the fee a deposit for the settlements dated in it -- what
    the company's invoice is compared with. Nothing here writes."""
    from accounting.payment_commission import commission_vat, deposit_fee, money, rounding_of
    rows = [ip for ip, _ in _payments(pm, month, next_month(month)) if float(ip.amount or 0.0) > 0]
    fee = vat = Decimal('0')
    for ip in rows:
        f, v = _charge(pm, ip)
        fee, vat = fee + f, vat + v
    deposits = _settlement_vouchers(pm, month, next_month(month))
    per_deposit = deposit_fee(pm)
    if per_deposit > 0 and deposits:
        extra = money(Decimal(str(per_deposit)) * deposits)
        fee += extra
        vat += Decimal(str(commission_vat(float(extra), rounding_of(pm))))
    return {'orders': len(rows), 'deposits': deposits, 'computed_fee': float(money(fee)),
            'computed_vat': float(money(vat))}


def _invoiced_months(pm: PaymentMethod) -> dict:
    return {inv.period_month: inv for inv in CommissionTaxInvoice.query.filter_by(payment_method_id=pm.id).all()}


def still_waiting(pm: PaymentMethod, invoiced: set) -> float:
    """What the pending account should hold, *invoiced* the months claimed:
    the VAT the settlements booked for the orders of the months still waiting
    (from the first), and their share of a deposit's difference -- less the
    VAT still to come of the invoiced months' unsettled orders, claimed ahead
    of their settlement."""
    first = month_start(pm.tax_invoice_from)
    rows = _payments(pm, first)
    month_of = {ip.id: month_start(day) for ip, day in rows}
    ids = list(month_of)
    if not ids:
        return 0.0
    lines = (SettlementLine.query.join(Voucher, Voucher.id == SettlementLine.voucher_id)
             .filter(SettlementLine.invoice_payment_id.in_(ids), Voucher.status == 'approved').all())
    held = Decimal('0')
    settled = defaultdict(Decimal)
    by_voucher = defaultdict(list)
    for ln in lines:
        settled[ln.invoice_payment_id] += Decimal(str(ln.amount_settled or 0.0))
        by_voucher[ln.voucher_id].append(ln)
        if month_of[ln.invoice_payment_id] not in invoiced:
            held += Decimal(str(ln.commission_vat or 0.0))
    # A deposit's VAT difference, shared by what each of its settlements' lines settled.
    links = (ClearingDepositSettlement.query.filter(ClearingDepositSettlement.voucher_id.in_(list(by_voucher)))
             .all() if by_voucher else [])
    deposits = defaultdict(list)
    for link in links:
        deposits[link.deposit_id].append(link.voucher_id)
    for deposit_id, voucher_ids in deposits.items():
        deposit = db.session.get(ClearingDeposit, deposit_id)
        if deposit is None or abs(float(deposit.vat_difference or 0.0)) < CENT or not deposit.voucher_id:
            continue
        mine = [ln for v in voucher_ids for ln in by_voucher[v]]
        total = sum(Decimal(str(ln.amount_settled or 0.0)) for ln in mine)
        if total <= 0:
            continue
        waiting = sum(Decimal(str(ln.amount_settled or 0.0)) for ln in mine
                      if month_of[ln.invoice_payment_id] not in invoiced)
        held += Decimal(str(deposit.vat_difference)) * waiting / total
    for ip, _ in rows:
        if month_of[ip.id] not in invoiced or float(ip.amount or 0.0) <= 0:
            continue
        rest = Decimal(str(ip.amount)) - settled[ip.id]
        if rest > Decimal('0.005'):
            _, vat = _charge(pm, ip)
            held -= vat * rest / Decimal(str(ip.amount))
    return round(float(held), 2)


def _claim_account(day: date) -> Account:
    from routes.clearing import commission_vat_account_on
    return commission_vat_account_on(day)


def _figures(data: dict) -> tuple:
    try:
        fee = round(float(data.get('fee_amount')), 2)
        vat = round(float(data.get('vat_amount')), 2)
    except (TypeError, ValueError):
        raise TaxInvoiceRefused('invalid_amount', 'الرسوم والضريبة أرقام')
    if fee < 0 or vat < 0:
        raise TaxInvoiceRefused('invalid_amount', 'الرسوم والضريبة لا تكون سالبة')
    return fee, vat


def preview(pm: Optional[PaymentMethod], data: dict, now: datetime) -> dict:
    """The invoice checked, against what the month computes to, and what its
    entry would move -- or TaxInvoiceRefused. Nothing here writes."""
    from accounting.payment_commission import _vat_rate
    from services.expense_vat import TAX_NUMBER
    if pm is None:
        raise TaxInvoiceRefused('not_found', 'وسيلة الدفع غير موجودة')
    if pm.tax_invoice_from is None:
        raise TaxInvoiceRefused('method_has_no_tax_invoices',
                                f'«{pm.name}» لا تُصدر فاتورة ضريبية شهرية: اضبطها في إعدادات وسائل الدفع')
    month = parse_month(data.get('month'))
    if month < month_start(pm.tax_invoice_from):
        raise TaxInvoiceRefused('month_before_invoices',
                                f'«{pm.name}» تُصدر فواتيرها من {pm.tax_invoice_from:%Y-%m}: '
                                'ضريبة ما قبله سُوّيت في إقرارها')
    invoiced = _invoiced_months(pm)
    if month in invoiced:
        raise TaxInvoiceRefused('month_already_invoiced',
                                f'فاتورة {month:%Y-%m} مُدخلة ({invoiced[month].invoice_number}): '
                                'ألغِ سندها لإدخالها من جديد')
    number = str(data.get('invoice_number') or '').strip()
    if not number:
        raise TaxInvoiceRefused('invoice_number_required', 'رقم الفاتورة مطلوب')
    tax_number = str(data.get('supplier_tax_number') or '').strip()
    if not TAX_NUMBER.match(tax_number):
        raise TaxInvoiceRefused('invalid_tax_number', 'الرقم الضريبي 15 رقمًا، أوله وآخره 3')
    try:
        invoice_day = date.fromisoformat(str(data.get('invoice_date') or '')[:10])
    except ValueError:
        raise TaxInvoiceRefused('invalid_invoice_date', 'تاريخ الفاتورة غير صالح')
    last_day = next_month(month) - timedelta(days=1)
    if invoice_day < last_day:     # Tabby's October: dated 31 Oct, 23:59:59; Tamara's: 1 Nov
        raise TaxInvoiceRefused('invoice_before_its_month_ends',
                                f'فاتورة {month:%Y-%m} تصدر في آخر يوم منه أو بعده: من {last_day.isoformat()}')
    if invoice_day > now.date():
        raise TaxInvoiceRefused('invoice_date_in_future', 'تاريخ الفاتورة بعد اليوم')
    fee, vat = _figures(data)
    expected_vat = round(float(Decimal(str(fee)) * _vat_rate()), 2)
    if abs(vat - expected_vat) > VAT_ROUNDING_ALLOWED + CENT:
        raise TaxInvoiceRefused('vat_not_its_rate',
                                f'الضريبة {vat:,.2f} ونسبتها من الرسوم {expected_vat:,.2f}: راجع الرقمين',
                                expected_vat=expected_vat)
    mine = computed(pm, month)
    pending_now = pending_vat(pm)
    remaining = still_waiting(pm, set(invoiced) | {month})
    rounding = round(pending_now - vat - remaining, 2)
    return {'payment_method_id': pm.id, 'month': month.strftime('%Y-%m'), 'invoice_number': number,
            'invoice_date': invoice_day.isoformat(), 'supplier_tax_number': tax_number,
            'fee_amount': fee, 'vat_amount': vat, **mine,
            'fee_difference': round(fee - mine['computed_fee'], 2),
            'vat_difference': round(vat - mine['computed_vat'], 2),
            'pending_vat': pending_now, 'still_waiting': remaining,
            'rounding_moved': rounding if abs(rounding) >= CENT else 0.0}


def enter(pm: Optional[PaymentMethod], data: dict, *, created_by: str, now: datetime) -> CommissionTaxInvoice:
    """The invoice entered and claimed on its date; the caller commits."""
    from accounting.voucher_engine import (
        _append_safe_transactions_for_voucher,
        generate_voucher_number,
        post_entry_of_approved_voucher,
    )
    p = preview(pm, data, now)
    invoice_day = date.fromisoformat(p['invoice_date'])
    claim = _claim_account(invoice_day)
    pending = pending_account(pm, claim)
    fee_account = db.session.get(Account, pm.fee_expense_account_id) if pm.fee_expense_account_id else None
    rounding = p['rounding_moved']
    if abs(rounding) >= CENT and fee_account is None:
        raise TaxInvoiceRefused('fee_account_id_required', f'«{pm.name}» بلا حساب مصروف عمولة')
    note = (str(data.get('note') or '').strip() or None)
    invoice = CommissionTaxInvoice(
        payment_method_id=pm.id, period_month=parse_month(p['month']), invoice_number=p['invoice_number'],
        invoice_date=invoice_day, supplier_tax_number=p['supplier_tax_number'], fee_amount=p['fee_amount'],
        vat_amount=p['vat_amount'], computed_fee=p['computed_fee'], computed_vat=p['computed_vat'],
        rounding_moved=rounding, note=note, created_by=created_by)
    db.session.add(invoice)
    db.session.flush()
    if p['vat_amount'] < CENT and abs(rounding) < CENT:
        return invoice
    when = datetime.combine(invoice_day, time(12, 0))
    voucher = Voucher(
        voucher_number=generate_voucher_number('adjustment', voucher_date=when),
        voucher_type='adjustment', date=when,
        description=(f'الفاتورة الضريبية لعمولات {pm.name} عن {p["month"]} رقم {p["invoice_number"]}: '
                     f'ضريبتها {p["vat_amount"]:,.2f}'),
        reference_type=REFERENCE_TYPE, reference_id=invoice.id, reference_number=p['invoice_number'],
        notes=note, created_by=created_by, status='approved', approved_by=created_by, approved_at=now,
        amount_cash=round(p['vat_amount'], 2), amount_gold=0.0,
    )
    db.session.add(voucher)
    db.session.flush()

    def line(account, side, amount, description):
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=account.id, line_type=side,
                                          amount_type='cash', amount=round(amount, 2), description=description))

    if p['vat_amount'] >= CENT:
        line(claim, 'debit', p['vat_amount'], 'ضريبة العمولة كما في الفاتورة الضريبية')
        line(pending, 'credit', p['vat_amount'], 'من ضريبة العمولة المنتظرة فاتورتها')
    if rounding >= CENT:          # the pending account held more: the commission's
        line(fee_account, 'debit', rounding, 'فرق تقريب ضريبة العمولة عن الفاتورة')
        line(pending, 'credit', rounding, 'فرق تقريب ضريبة العمولة عن الفاتورة')
    elif rounding <= -CENT:       # it held less: the commission was the VAT's
        line(pending, 'debit', -rounding, 'فرق تقريب ضريبة العمولة عن الفاتورة')
        line(fee_account, 'credit', -rounding, 'فرق تقريب ضريبة العمولة عن الفاتورة')
    db.session.flush()
    post_entry_of_approved_voucher(voucher, posted_by=created_by)
    _append_safe_transactions_for_voucher(voucher, created_by=created_by)
    invoice.voucher_id = voucher.id
    db.session.flush()
    return invoice


def release_voucher(voucher: Voucher) -> None:
    """The invoice whose voucher was cancelled is undone: its month waits again. The caller commits."""
    invoice = CommissionTaxInvoice.query.filter_by(voucher_id=voucher.id).first()
    if invoice is not None:
        db.session.delete(invoice)
        db.session.flush()


def undo(invoice: CommissionTaxInvoice) -> None:
    """An invoice that posted nothing (no VAT, no rounding) is undone here; the caller commits."""
    if invoice.voucher_id:
        raise TaxInvoiceRefused('invoice_has_voucher', 'ألغِ سند الفاتورة لإلغائها')
    db.session.delete(invoice)
    db.session.flush()


def months(pm: PaymentMethod, today: date) -> dict:
    """The method's months from its first: each its orders, what they compute
    to, its invoice if entered, and whether it waits (ended, no invoice) or is
    still open. Nothing here writes."""
    if pm.tax_invoice_from is None:
        return {'payment_method_id': pm.id, 'tax_invoice_from': None, 'pending_vat': pending_vat(pm), 'months': []}
    invoiced = _invoiced_months(pm)
    out = []
    month = month_start(pm.tax_invoice_from)
    current = month_start(today)
    while month <= current:
        figures = computed(pm, month)
        invoice = invoiced.get(month)
        state = 'invoiced' if invoice else ('open' if month == current else 'waiting')
        out.append({'month': month.strftime('%Y-%m'), **figures, 'state': state,
                    'invoice': invoice.to_dict() if invoice else None,
                    'vat_difference': (round(invoice.vat_amount - figures['computed_vat'], 2) if invoice else None)})
        month = next_month(month)
    return {'payment_method_id': pm.id, 'payment_method_name': pm.name,
            'tax_invoice_from': pm.tax_invoice_from.isoformat(), 'pending_vat': pending_vat(pm),
            'still_waiting': still_waiting(pm, set(invoiced)), 'months': list(reversed(out))}


def missing(pm: PaymentMethod, today: date, grace_days: int) -> list:
    """(month, its figures) of the months ended more than *grace_days* ago
    with orders and no invoice."""
    if pm.tax_invoice_from is None:
        return []
    invoiced = _invoiced_months(pm)
    out = []
    month = month_start(pm.tax_invoice_from)
    while next_month(month) + timedelta(days=grace_days) < today:
        if month not in invoiced:
            figures = computed(pm, month)
            if figures['orders']:
                out.append((month, figures))
        month = next_month(month)
    return out
