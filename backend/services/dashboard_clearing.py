"""What the banks and the instalment companies still owe us, for the manager's dashboard (DASH-5).

The owner, 30 Oct 2026 (agreeing to all advised): a card, Tabby or Tamara
payment sits in its clearing safe until its deposit. Each clearing safe: what
it is owed (routes/clearing._compute_clearing_due_amount -- the one amount),
how many payments wait and the oldest one's day (method_open_payments), and
when it deposits and whether it is late -- by the scheduler's own reading.

The 31 Oct copy (the owner: «تتبع أي مشكلة»): this card said Tamara late since
21 Oct and Mada on time; the scheduler's alarm said the opposite. The card
made the deposit day from the oldest payment alone, blind to a weekly batch
and to a method's minimum -- Tamara's 2,392 waited below its 2,500. Now:

  next_deposit  the earliest deposit the scheduler will make (method_dues,
                looking ahead) -- none while what waits is below its minimum
  below_minimum payments wait, and no deposit is due for them
  overdue       the alarm's own answer (overdue_settlements), and its day

Nothing here writes.
"""
from __future__ import annotations

from datetime import datetime, timedelta

# How far ahead the next deposit is looked for: a weekly batch is at most a
# week from closing, its deposit days after.
_AHEAD_DAYS = 21


def clearing_pending(now: datetime) -> dict:
    from clearing_settlement_scheduler import (
        method_dues, method_open_payments, overdue_grace_hours, overdue_settlements, public_holidays,
    )
    from models import PaymentMethod, SafeBox
    from routes.clearing import _compute_clearing_due_amount

    holidays = public_holidays()
    late = {fact.subject_key: fact.detail.get('due_day') for fact in overdue_settlements(now, overdue_grace_hours())}
    safes = []
    for sb in SafeBox.query.filter_by(safe_type='clearing', is_active=True).order_by(SafeBox.id).all():
        due = float(_compute_clearing_due_amount(sb.id) or 0.0)
        if due < 0.005:
            continue
        methods = PaymentMethod.query.filter_by(default_safe_box_id=sb.id).order_by(PaymentMethod.id).all()
        waiting = [day for pm in methods for _id, day, _rest in method_open_payments(pm)]
        ahead = now.date() + timedelta(days=_AHEAD_DAYS)
        deposits = [d.deposit_date for pm in methods for d in method_dues(pm, ahead, holidays)]
        late_since = min((late[f'payment_method:{pm.id}'] for pm in methods
                          if f'payment_method:{pm.id}' in late), default=None)
        safes.append({
            'safe': sb.name,
            'method': ' / '.join(pm.name for pm in methods) or None,
            'amount': round(due, 2),
            'payments': len(waiting),
            'oldest': min(waiting).isoformat() if waiting else None,
            'next_deposit': min(deposits).isoformat() if deposits else None,
            'below_minimum': bool(waiting) and not deposits,
            'overdue': late_since is not None,
            'overdue_since': late_since,
        })
    return {'total': round(sum(s['amount'] for s in safes), 2), 'safes': safes,
            'overdue': sum(1 for s in safes if s['overdue'])}
