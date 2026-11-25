"""A deposit is confirmed by what reached the bank (ADR-100).

The owner, 24 Nov 2026: the books booked what the settlement computed, on the
day the deposit was due, and never asked the bank -- on two installment
companies' 2026 deposits 290.94 and 348.59 of commission went unseen, and a
plan does not decide its rate for sure (an order on 4 installments at 5.99 %
where its others were 6.99 %). For any method set to have its deposits
confirmed, the accountant enters what the bank received for one or more of its
settlement vouchers; the difference from their nets is posted, dated the
deposit's day, between the bank and the commission and its VAT -- the bank's
figure stands. A settlement is confirmed once; an approved voucher is not
edited. A difference beyond the method's allowance needs a note: a missing
order or a return, not a commission.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time
from decimal import Decimal
from typing import List, Optional, Sequence

from models import (
    Account,
    ClearingDeposit,
    ClearingDepositSettlement,
    PaymentMethod,
    SafeBox,
    Voucher,
    VoucherAccountLine,
    db,
)


class DepositRefused(ValueError):
    def __init__(self, code: str, message: str, **detail):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


@dataclass
class SettlementNet:
    voucher: Voucher
    bank_account_id: int
    net: float


@dataclass
class DepositPreview:
    payment_method: PaymentMethod
    settlements: List[SettlementNet]
    amount_received: float
    expected_net: float
    difference: float          # expected - received
    fee_difference: float
    vat_difference: float
    note_required: bool

    def to_dict(self) -> dict:
        return {
            'payment_method_id': self.payment_method.id,
            'settlements': [{'voucher_id': s.voucher.id, 'voucher_number': s.voucher.voucher_number,
                             'date': s.voucher.date.date().isoformat() if s.voucher.date else None,
                             'net': s.net} for s in self.settlements],
            'amount_received': self.amount_received,
            'expected_net': self.expected_net,
            'difference': self.difference,
            'fee_difference': self.fee_difference,
            'vat_difference': self.vat_difference,
            'allowed_difference': float(self.payment_method.deposit_difference_allowed or 0.0),
            'note_required': self.note_required,
        }


def _bank_account_ids() -> set:
    return {a for (a,) in db.session.query(SafeBox.account_id)
            .filter(db.func.lower(SafeBox.safe_type) == 'bank', SafeBox.account_id.isnot(None)).all()}


def _confirmed_voucher_ids(voucher_ids=None) -> set:
    q = db.session.query(ClearingDepositSettlement.voucher_id)
    if voucher_ids is not None:
        q = q.filter(ClearingDepositSettlement.voucher_id.in_(list(voucher_ids)))
    return {v for (v,) in q.all()}


def settlement_net(voucher: Voucher, bank_ids: Optional[set] = None) -> SettlementNet:
    """What a settlement voucher put in the bank: its debit to a bank account."""
    bank_ids = _bank_account_ids() if bank_ids is None else bank_ids
    lines = [ln for ln in VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
             if ln.line_type == 'debit' and ln.amount_type == 'cash' and ln.account_id in bank_ids]
    accounts = {ln.account_id for ln in lines}
    if len(accounts) != 1:
        raise DepositRefused('settlement_has_no_bank_line',
                             f'السند {voucher.voucher_number} لا يُظهر مبلغًا أودع في بنك واحد')
    return SettlementNet(voucher, accounts.pop(), round(sum(float(ln.amount or 0.0) for ln in lines), 2))


def unconfirmed_settlements(pm: PaymentMethod) -> List[SettlementNet]:
    """The method's approved settlement vouchers no deposit carries yet, oldest first."""
    if not pm.default_safe_box_id:
        return []
    vouchers = (Voucher.query
                .filter(Voucher.reference_type == 'clearing_settlement',
                        Voucher.reference_id == pm.default_safe_box_id,
                        Voucher.status == 'approved')
                .order_by(Voucher.date.asc(), Voucher.id.asc()).all())
    confirmed = _confirmed_voucher_ids([v.id for v in vouchers])
    bank_ids = _bank_account_ids()
    out = []
    for v in vouchers:
        if v.id in confirmed:
            continue
        try:
            out.append(settlement_net(v, bank_ids))
        except DepositRefused:
            continue
    return out


def _split(difference: Decimal, day: date) -> tuple:
    """A difference into its commission and the commission's VAT: the VAT the
    rate's part of it (15/115 at 15 %), none when tax is off."""
    from accounting.payment_commission import money, _vat_rate
    rate = _vat_rate()
    if rate <= 0:
        return difference, Decimal('0')
    fee = money(difference / (Decimal(1) + rate))
    return fee, difference - fee


def preview(pm: PaymentMethod, voucher_ids: Sequence[int], amount_received, on: Optional[date] = None) -> DepositPreview:
    from accounting.payment_commission import money
    if pm is None:
        raise DepositRefused('not_found', 'وسيلة الدفع غير موجودة')
    try:
        received = money(amount_received)
    except Exception:
        raise DepositRefused('invalid_amount_received', 'المبلغ الوارد غير صالح')
    if received <= 0:
        raise DepositRefused('invalid_amount_received', 'المبلغ الوارد أكبر من صفر')
    ids = []
    for raw in voucher_ids or []:
        try:
            ids.append(int(raw))
        except (TypeError, ValueError):
            raise DepositRefused('invalid_voucher_ids', 'سندات التسوية غير صالحة')
    if not ids:
        raise DepositRefused('no_settlements', 'اختر سند تسوية واحدًا على الأقل')
    if len(set(ids)) != len(ids):
        raise DepositRefused('invalid_voucher_ids', 'سند تسوية مكرّر')
    vouchers = Voucher.query.filter(Voucher.id.in_(ids)).all()
    if len(vouchers) != len(ids):
        raise DepositRefused('not_found', 'سند تسوية غير موجود')
    for v in vouchers:
        if v.reference_type != 'clearing_settlement' or v.reference_id != pm.default_safe_box_id:
            raise DepositRefused('not_this_methods_settlement',
                                 f'السند {v.voucher_number} ليس تسوية «{pm.name}»')
        if v.status != 'approved':
            raise DepositRefused('settlement_not_approved', f'السند {v.voucher_number} غير معتمد')
    already = _confirmed_voucher_ids(ids)
    if already:
        numbers = '، '.join(v.voucher_number for v in vouchers if v.id in already)
        raise DepositRefused('settlement_already_confirmed', f'سبق تأكيد إيداع {numbers}')
    bank_ids = _bank_account_ids()
    nets = [settlement_net(v, bank_ids) for v in sorted(vouchers, key=lambda v: (v.date, v.id))]
    if len({n.bank_account_id for n in nets}) != 1:
        raise DepositRefused('settlements_in_different_banks', 'إيداع واحد في بنك واحد: السندات في بنوك مختلفة')
    expected = money(sum(n.net for n in nets))
    difference = expected - received
    fee, vat = _split(difference, on or date.today())
    allowed = money(pm.deposit_difference_allowed or 0.0)
    return DepositPreview(pm, nets, float(received), float(expected), float(difference),
                          float(fee), float(vat), abs(difference) > allowed)


def confirm(pm: PaymentMethod, voucher_ids: Sequence[int], amount_received, deposit_day: date,
            bank_reference: Optional[str] = None, note: Optional[str] = None,
            created_by: str = 'system', now: Optional[datetime] = None) -> ClearingDeposit:
    """Confirm a deposit; the caller commits. *now* is when it was confirmed
    -- the voucher's approval -- given by the caller (the clock's)."""
    from routes.clearing import commission_vat_account_on
    from accounting.voucher_engine import (
        _append_safe_transactions_for_voucher,
        generate_voucher_number,
        post_entry_of_approved_voucher,
    )
    if not isinstance(deposit_day, date):
        raise DepositRefused('invalid_deposit_date', 'تاريخ الإيداع غير صالح')
    p = preview(pm, voucher_ids, amount_received, deposit_day)
    note = (note or '').strip() or None
    if p.note_required and not note:
        raise DepositRefused('note_required',
                             f'الفرق {abs(p.difference):,.2f} أكبر من المسموح '
                             f'({float(pm.deposit_difference_allowed or 0):,.2f}): اكتب سببه -- '
                             'طلب ناقص أو مرتجع لا عمولة', **p.to_dict())
    # The deposit's day is the bank's; a settlement's day is the schedule's
    # guess and may be a day after it (AV-2026-00491: dated 14 Oct, the bank's
    # 13 Oct). No order between them is asked.

    deposit = ClearingDeposit(
        payment_method_id=pm.id, deposit_date=deposit_day, amount_received=p.amount_received,
        expected_net=p.expected_net, difference=p.difference, fee_difference=p.fee_difference,
        vat_difference=p.vat_difference, bank_reference=(bank_reference or '').strip() or None,
        note=note, created_by=created_by,
    )
    deposit.settlements = [ClearingDepositSettlement(voucher_id=s.voucher.id) for s in p.settlements]
    db.session.add(deposit)
    db.session.flush()

    if abs(p.difference) >= 0.005:
        bank_account = Account.query.get(p.settlements[0].bank_account_id)
        fee_account = Account.query.get(pm.fee_expense_account_id) if pm.fee_expense_account_id else None
        if fee_account is None:
            raise DepositRefused('fee_account_id_required', f'«{pm.name}» بلا حساب مصروف عمولة')
        vat_account = commission_vat_account_on(deposit_day, payment_method=pm) if abs(p.vat_difference) >= 0.005 else None
        shortfall = p.difference > 0      # the bank received less: a commission more
        when = datetime.combine(deposit_day, time(12, 0))
        numbers = '، '.join(s.voucher.voucher_number for s in p.settlements)
        voucher = Voucher(
            voucher_number=generate_voucher_number('adjustment', voucher_date=when),
            voucher_type='adjustment', date=when,
            description=(f'تأكيد إيداع {pm.name}: وصل البنك {p.amount_received:,.2f} '
                         f'والمتوقع {p.expected_net:,.2f} ({numbers})'),
            reference_type='clearing_deposit', reference_id=deposit.id,
            reference_number=(bank_reference or '').strip() or None, notes=note,
            created_by=created_by, status='approved', approved_by=created_by, approved_at=now or when,
            amount_cash=round(abs(p.difference), 2), amount_gold=0.0,
        )
        db.session.add(voucher)
        db.session.flush()
        side_fee, side_bank = ('debit', 'credit') if shortfall else ('credit', 'debit')
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=fee_account.id, line_type=side_fee,
                                          amount_type='cash', amount=round(abs(p.fee_difference), 2),
                                          description='فرق عمولة التحصيل عند الإيداع'))
        if vat_account is not None:
            db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=vat_account.id,
                                              line_type=side_fee, amount_type='cash',
                                              amount=round(abs(p.vat_difference), 2),
                                              description='فرق ضريبة عمولة التحصيل عند الإيداع'))
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=bank_account.id, line_type=side_bank,
                                          amount_type='cash', amount=round(abs(p.difference), 2),
                                          description='الإيداع كما وصل البنك'))
        db.session.flush()
        post_entry_of_approved_voucher(voucher, posted_by=created_by)
        _append_safe_transactions_for_voucher(voucher, created_by=created_by)
        deposit.voucher_id = voucher.id
        db.session.flush()
    return deposit


def deposit_holding(voucher_id: int) -> Optional[ClearingDeposit]:
    """The confirmed deposit that carries a settlement voucher, if any."""
    link = ClearingDepositSettlement.query.filter_by(voucher_id=voucher_id).first()
    return link.deposit if link else None


def release(deposit: ClearingDeposit) -> None:
    """Undo a confirmation whose difference voucher was cancelled, or which
    posted none: its settlements are unconfirmed again. The caller commits."""
    db.session.delete(deposit)
    db.session.flush()
