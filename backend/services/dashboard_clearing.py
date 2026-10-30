"""What the banks and the instalment companies still owe us, for the manager's dashboard (DASH-5).

The owner, 30 Oct 2026 (agreeing to all advised): a card, Tabby or Tamara
payment sits in its clearing safe until its deposit. Each clearing safe: what
it is owed (routes/clearing._compute_clearing_due_amount -- the one amount),
how many payments wait and the oldest one's day (method_open_payments -- the
scheduler's and the overdue alarm's reading), and when its method's schedule
deposits it (services/settlement_schedule, ADR-037) -- overdue when that day
has passed. Nothing here writes.
"""
from __future__ import annotations

from datetime import date


def clearing_pending(today: date) -> dict:
    from clearing_settlement_scheduler import method_open_payments, public_holidays
    from models import PaymentMethod, SafeBox
    from routes.clearing import _compute_clearing_due_amount
    from services.settlement_schedule import deposit_for_sale, schedule_of

    holidays = public_holidays()
    safes = []
    for sb in SafeBox.query.filter_by(safe_type='clearing', is_active=True).order_by(SafeBox.id).all():
        due = float(_compute_clearing_due_amount(sb.id) or 0.0)
        if due < 0.005:
            continue
        methods = PaymentMethod.query.filter_by(default_safe_box_id=sb.id).order_by(PaymentMethod.id).all()
        waiting = [(pm, day) for pm in methods for _id, day, _rest in method_open_payments(pm)]
        oldest_pm, oldest = min(waiting, key=lambda w: w[1]) if waiting else (methods[0] if methods else None, None)
        deposit = deposit_for_sale(schedule_of(oldest_pm), oldest, holidays) if (oldest_pm and oldest) else None
        safes.append({
            'safe': sb.name,
            'method': ' / '.join(pm.name for pm in methods) or None,
            'amount': round(due, 2),
            'payments': len(waiting),
            'oldest': oldest.isoformat() if oldest else None,
            'next_deposit': deposit.isoformat() if deposit else None,
            'overdue': bool(deposit and deposit < today),
        })
    return {'total': round(sum(s['amount'] for s in safes), 2), 'safes': safes,
            'overdue': sum(1 for s in safes if s['overdue'])}
