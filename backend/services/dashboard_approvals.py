"""What waits for the manager, for the manager's dashboard (DASH-6).

The owner, 30 Oct 2026 (agreeing to all advised): the dashboard said how many
invoices are unposted -- the rejected ones counted with them -- and nothing of
the rest that waits for an approver. Each queue by its own reading:

  invoices      held, not rejected -- the bell's (/pending-actions)
  vouchers      pending, no entry yet -- safe_pending's (an entry's is V0's
                legacy, waiting for repair, not approval)
  bonuses       pending -- the bonuses' screen's
  reservations  an office's, approved or pending, no purchase invoice yet --
                the bell's

Nothing here writes.
"""
from __future__ import annotations

from sqlalchemy import func


def _queue(query, amount, oldest):
    count, total, first = query.with_entities(func.count(), func.coalesce(func.sum(amount), 0.0),
                                              func.min(oldest)).one()
    return {'count': int(count or 0), 'amount': round(float(total or 0.0), 2),
            'oldest': first.date().isoformat() if hasattr(first, 'date') else (first.isoformat() if first else None)}


def approvals() -> dict:
    from models import EmployeeBonus, Invoice, OfficeReservation, Voucher

    queues = {
        'invoices': _queue(Invoice.query.filter(Invoice.is_posted.is_(False), Invoice.status != 'rejected'),
                           Invoice.total, Invoice.date),
        'vouchers': _queue(Voucher.query.filter(Voucher.status == 'pending', Voucher.journal_entry_id.is_(None)),
                           Voucher.amount_cash, Voucher.date),
        'bonuses': _queue(EmployeeBonus.query.filter(EmployeeBonus.status == 'pending'),
                          EmployeeBonus.amount, EmployeeBonus.created_at),
        'reservations': _queue(OfficeReservation.query.filter(OfficeReservation.purchase_invoice_id.is_(None),
                                                              OfficeReservation.status.in_(['approved', 'pending'])),
                               OfficeReservation.total_amount, OfficeReservation.reservation_date),
    }
    queues['total'] = sum(q['count'] for q in queues.values())
    return queues
