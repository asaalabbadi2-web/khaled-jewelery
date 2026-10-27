"""A reservation's deposit is what its standing vouchers paid (the owner, 27 Oct 2026).

The deposit voucher is the payment; the reservation's paid_amount and
payment_status say what it holds. They were written once, at creation, and a
cancelled voucher left the reservation reading paid -- refused its own
cancellation (RES-...-0040, 27 Oct 2026). Here they are read from the
vouchers that still name it, and written back when one of them is cancelled.

An executed reservation's vouchers name its purchase (the execution relinks
them), so only an open reservation's deposit is read here; an executed one's
is its purchase's payment.
"""
from models import Voucher

DEAD = ('cancelled', 'rejected')


def payment_status_of(paid: float, total: float) -> str:
    if paid >= total and total > 0:
        return 'paid'
    return 'partial' if paid > 0 else 'pending'


def standing_deposit_vouchers(reservation) -> list:
    return (Voucher.query.filter(Voucher.reference_type == 'office_reservation',
                                 Voucher.reference_id == reservation.id,
                                 Voucher.status.notin_(DEAD))
            .order_by(Voucher.id).all())


def sync_deposit(reservation) -> float:
    """The reservation's paid_amount and payment_status from its standing vouchers."""
    paid = round(sum(float(v.amount_cash or 0.0) for v in standing_deposit_vouchers(reservation)), 2)
    reservation.paid_amount = paid
    reservation.payment_status = payment_status_of(paid, float(reservation.total_amount or 0.0))
    return paid
