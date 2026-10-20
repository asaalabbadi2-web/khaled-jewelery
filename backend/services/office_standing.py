"""What stands between us and an office (the owner, 20 Oct 2026).

An office is stopped only when it is settled: its deposit holds no gold (our
gold there, ADR-052), its supplier account no balance in riyals or any karat
(the trade between us), and no reservation of it waits to be executed. Read
from the ledger, as the offices list reads them.
"""
from __future__ import annotations

from sqlalchemy import func

from models import OfficeReservation, Supplier, db

CENT = 0.005
DUST = 0.0005


def what_stands_between(office) -> list[str]:
    """The reasons an office is not settled: 'deposit', 'cash', 'gold',
    'open_reservations' -- none when it is."""
    from services.live_balances import live_balances_by_account_ids
    from services.office_deposits import deposit_of
    from services.party_live_balances import compute_live_supplier_balances

    reasons = []
    supplier = db.session.get(Supplier, office.supplier_id) if office.supplier_id else None
    if supplier is not None:
        safe = deposit_of(supplier)
        if safe is not None:
            held = live_balances_by_account_ids([safe.account_id]).get(safe.account_id) or {}
            if any(abs(float(held.get(f'{k}k') or 0.0)) >= DUST for k in (18, 21, 22, 24)):
                reasons.append('deposit')
        balance = compute_live_supplier_balances([supplier]).get(supplier.id) or {}
        if abs(float(balance.get('cash') or 0.0)) >= CENT:
            reasons.append('cash')
        if any(abs(float(balance.get(f'{k}k') or 0.0)) >= DUST for k in (18, 21, 22, 24)):
            reasons.append('gold')
    waiting = (db.session.query(func.count(OfficeReservation.id))
               .filter(OfficeReservation.office_id == office.id,
                       OfficeReservation.purchase_invoice_id.is_(None),
                       func.coalesce(OfficeReservation.status, '') != 'cancelled')
               .scalar())
    if waiting:
        reasons.append('open_reservations')
    return reasons


SAID = {
    'deposit': 'في وديعته ذهب لنا',
    'cash': 'بيننا وبينه رصيد نقدي',
    'gold': 'بيننا وبينه رصيد ذهب',
    'open_reservations': 'له حجوزات لم تُنفَّذ',
}
