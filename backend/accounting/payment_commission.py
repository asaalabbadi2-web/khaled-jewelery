"""What a payment method deducts from a payment: its rate and its fixed amount a transaction (COMMISSION-3).

The one computation. The settlement takes it (COMMISSION-1: the commission is
taken at its settlement and posted there, never at the invoice); an invoice
keeps it on each payment as what will be deducted -- the estimate its cash
profit is less by, and shows -- from its method, never from its screen (the
owner, 29 Oct 2026: the screens took the rate alone). Its VAT is the
settlement's (commission_vat here), and comes off no profit.

ADR-100 (the owner, 24 Nov 2026), proven on the 2026 bank deposits of two
installment companies and then made general -- «اجعلها شاملة لمثل هكذا وسائل
ويتم ضبطها في الإعدادات». Each is a method's setting (POLICY), none a name:
- plans: a payment names one, and its rate is kept on the payment;
- a fixed amount an order, and a fee a deposit (a «payout fee»), once;
- order by order (each order's commission and VAT on its own) or one
  commission on the settlement's total (as a card network's bank line);
- the rounding: half up, or half to even;
- a part of the rate refunded on a return, rounded apart from the rest, each
  part's VAT on its own (one company splits 6.99 % into 4.99 % refundable and
  2 % not).
Every amount to the halala by Decimal -- round() on a float is not: 198.715 +
1.50 came out 200.71, and 8 of 25 deposits did not match.
"""
from __future__ import annotations

from decimal import ROUND_HALF_EVEN, ROUND_HALF_UP, Decimal
from typing import Iterable, Optional, Sequence, Tuple


class PlanRefused(ValueError):
    """A payment by a method with plans names none of them."""

    def __init__(self, code: str, method_name: str, offered: Sequence[int]):
        self.code = code
        self.offered = list(offered)
        listed = '، '.join(str(n) for n in offered)
        if code == 'installments_required':
            message = f'اختر خطة «{method_name}»: عدد الدفعات ({listed})'
        else:
            message = f'خطة «{method_name}» غير موجودة: عدد الدفعات {listed}'
        super().__init__(message)
        self.message = message


def money(value, rounding=ROUND_HALF_UP) -> Decimal:
    """*value* to the halala, half up unless told."""
    return Decimal(str(value or 0)).quantize(Decimal('0.01'), rounding=rounding)


ROUNDINGS = {'half_up': ROUND_HALF_UP, 'half_even': ROUND_HALF_EVEN}


def rounding_of(pm):
    """The method's rounding (POLICY): 'half_up' unless set 'half_even'."""
    return ROUNDINGS.get(str(getattr(pm, 'commission_rounding', None) or 'half_up'), ROUND_HALF_UP)


def refundable_rate(pm) -> float:
    """The part of the rate refunded on a return, rounded apart (POLICY); 0: one part."""
    return float(getattr(pm, 'commission_refundable_rate', 0.0) or 0.0) if pm is not None else 0.0


def _vat_rate() -> Decimal:
    """The settings' VAT rate on a commission; 0 when tax is off."""
    from models import Settings
    try:
        row = Settings.query.first()
    except Exception:
        row = None
    if row is not None and not bool(getattr(row, 'tax_enabled', True)):
        return Decimal('0')
    try:
        rate = float(getattr(row, 'tax_rate', 0.15) if row is not None else 0.15)
    except (TypeError, ValueError):
        rate = 0.15
    if rate > 1.0:
        rate = rate / 100.0
    return Decimal(str(abs(rate)))


def commission_vat(fee_amount, rounding=ROUND_HALF_UP) -> float:
    """VAT on a commission: entered net of VAT, its VAT the settings' rate (0
    when tax is off), half up. The one computation: the settlement voucher,
    an invoice's estimate, and the net a flexible plan's minimum is measured
    against (services/settlement_schedule.py, ADR-037)."""
    fee = money(fee_amount)
    if fee <= 0:
        return 0.0
    return float(money(fee * _vat_rate(), rounding))


def _rate(pm) -> float:
    return float(getattr(pm, 'commission_rate', 0.0) or 0.0) if pm is not None else 0.0


def _fixed(pm) -> float:
    return float(getattr(pm, 'commission_fixed_amount', 0.0) or 0.0) if pm is not None else 0.0


def deposit_fee(pm) -> float:
    """What the method takes once a deposit, before VAT -- a «payout fee» (ADR-100)."""
    return float(getattr(pm, 'deposit_fixed_fee', 0.0) or 0.0) if pm is not None else 0.0


def per_order(pm) -> bool:
    return bool(getattr(pm, 'commission_per_order', False)) if pm is not None else False


def plans_of(pm) -> dict:
    """{installments: rate} of the method's plans; {} for a method without."""
    if pm is None:
        return {}
    return {int(p.installments): float(p.commission_rate or 0.0)
            for p in (getattr(pm, 'plans', None) or [])}


def plan_rate(pm, installments, required: bool = True) -> Tuple[Optional[int], float]:
    """(installments, rate) of a payment by *pm*. A method with plans takes
    one of them and nothing else (PlanRefused); a method without takes its
    rate, and an installments sent with it is not kept. *required* is a sale's:
    a return refunded by the method names no plan of its own and takes the
    method's rate, as before (its fee on a return is not known -- Known Gaps)."""
    plans = plans_of(pm)
    if not plans:
        return None, _rate(pm)
    offered = sorted(plans)
    if installments in (None, '', 0):
        if not required:
            return None, _rate(pm)
        raise PlanRefused('installments_required', getattr(pm, 'name', ''), offered)
    try:
        n = int(installments)
    except (TypeError, ValueError):
        raise PlanRefused('installments_unknown', getattr(pm, 'name', ''), offered)
    if n not in plans:
        raise PlanRefused('installments_unknown', getattr(pm, 'name', ''), offered)
    return n, plans[n]


def _order_charge(pm, amount: Decimal, rate: float) -> Tuple[Decimal, Decimal]:
    """(commission, its VAT) of one order at *rate*, by the method's rounding.
    One part: the rate and the fixed amount together, the VAT on the whole.
    With a refundable part: that part, the rest of the rate and the fixed
    amount each rounded on its own, and each one's VAT."""
    fixed = _fixed(pm)
    if amount <= 0 or (rate <= 0 and fixed <= 0):
        return Decimal('0'), Decimal('0')
    mode = rounding_of(pm)
    hundred = Decimal(100)
    refundable = min(refundable_rate(pm), float(rate))
    if refundable <= 0:
        fee = money(amount * Decimal(str(rate)) / hundred + Decimal(str(fixed)), mode)
        return fee, money(commission_vat(fee, mode))
    parts = [money(amount * Decimal(str(refundable)) / hundred, mode),
             money(amount * (Decimal(str(rate)) - Decimal(str(refundable))) / hundred, mode),
             money(fixed)]
    return (sum(parts, Decimal('0')),
            sum((money(commission_vat(p, mode)) for p in parts), Decimal('0')))


def commission_of(pm, amount: float, transactions: int = 1, rate: Optional[float] = None) -> float:
    """The commission on *amount* over *transactions* payments: amount x rate %
    + the fixed amount a transaction -- nothing on nothing paid. *rate* is a
    payment's own (its plan's, kept on it); the method's when not given."""
    amount = money(amount)
    r = _rate(pm) if rate is None else float(rate or 0.0)
    fixed = _fixed(pm)
    if amount <= 0 or (r <= 0 and fixed <= 0):
        return 0.0
    return float(money(amount * Decimal(str(r)) / Decimal(100)
                       + Decimal(str(fixed)) * max(int(transactions or 1), 1)))


def payment_commission(pm, amount: float, installments=None, rate: Optional[float] = None,
                       required: bool = True) -> dict:
    """One payment's: {installments, commission_rate, commission_amount,
    commission_vat, net_amount}. *rate* given is the payment's kept rate (a
    payment re-read, never re-priced); otherwise its plan's (PlanRefused) or
    its method's."""
    if rate is None:
        installments, rate = plan_rate(pm, installments, required=required)
    amount_d = money(amount)
    fee, vat = _order_charge(pm, amount_d, float(rate or 0.0))
    return {
        'installments': installments,
        'commission_rate': float(rate or 0.0),
        'commission_amount': float(fee),
        'commission_vat': float(vat),
        'net_amount': float(amount_d - fee - vat),
    }


def settlement_commission(pm, payments: Iterable[Tuple[float, Optional[float]]]) -> Tuple[float, float]:
    """(commission, its VAT) a deposit of *payments* -- (open amount, the
    payment's kept rate or None for the method's) -- carries: the only place a
    commission is taken (COMMISSION-1).

    A method computed per order: each order's commission and VAT on its own,
    summed. Otherwise one commission on the total, as before. The fee a
    deposit, if any, once, with its VAT."""
    payments = [(money(a), r) for a, r in payments if money(a) > 0]
    if not payments:
        return 0.0, 0.0
    if per_order(pm):
        fee = Decimal('0')
        vat = Decimal('0')
        for amount, r in payments:
            one, its_vat = _order_charge(pm, amount, _rate(pm) if r is None else float(r or 0.0))
            fee += one
            vat += its_vat
    else:
        gross = sum((a for a, _ in payments), Decimal('0'))
        fee = money(commission_of(pm, gross, len(payments)))
        vat = money(commission_vat(fee))
    extra = money(deposit_fee(pm))
    if extra > 0:
        fee += extra
        vat += money(commission_vat(extra, rounding_of(pm)))
    return float(fee), float(vat)


def settlement_net(pm, payments: Sequence[Tuple[float, Optional[float]]]) -> float:
    """What reaches the bank from a deposit of *payments*: their total less
    the settlement's commission and its VAT."""
    gross = sum((money(a) for a, _ in payments), Decimal('0'))
    fee, vat = settlement_commission(pm, payments)
    return float(gross - money(fee) - money(vat))
