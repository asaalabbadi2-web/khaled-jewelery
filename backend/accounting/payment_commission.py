"""What a payment method deducts from a payment: its rate and its fixed amount a transaction (COMMISSION-3).

The one computation. The settlement takes it (COMMISSION-1: the commission is
taken at its settlement and posted there, never at the invoice); an invoice
keeps it on each payment as what will be deducted -- the estimate its cash
profit is less by, and shows -- from its method, never from its screen (the
owner, 29 Oct 2026: the screens took the rate alone). Its VAT is the
settlement's (routes/clearing.commission_vat), and comes off no profit.
"""
from __future__ import annotations


def commission_of(pm, amount: float, transactions: int = 1) -> float:
    """The commission on *amount* over *transactions* payments: amount x rate %
    + the fixed amount a transaction -- nothing on nothing paid."""
    amount = float(amount or 0.0)
    rate = float(getattr(pm, 'commission_rate', 0.0) or 0.0) if pm is not None else 0.0
    fixed = float(getattr(pm, 'commission_fixed_amount', 0.0) or 0.0) if pm is not None else 0.0
    if amount <= 0.0 or (rate <= 0.0 and fixed <= 0.0):
        return 0.0
    return round(amount * rate / 100.0 + fixed * max(int(transactions or 1), 1), 2)


def payment_commission(pm, amount: float) -> dict:
    """One payment's: {commission_rate, commission_amount, commission_vat, net_amount}."""
    from routes.clearing import commission_vat
    amount = float(amount or 0.0)
    fee = commission_of(pm, amount)
    vat = commission_vat(fee)
    return {
        'commission_rate': float(getattr(pm, 'commission_rate', 0.0) or 0.0) if pm is not None else 0.0,
        'commission_amount': fee,
        'commission_vat': vat,
        'net_amount': round(amount - fee - vat, 2),
    }
