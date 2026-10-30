"""The month's losing invoices, by employee, for the manager's dashboard (DASH-9).

The owner, 30 Oct 2026 (agreeing to all advised): the dashboard said nothing of
the employees. Who leads is the race's own reading (/home/leaderboard, its
points with the losses already off them -- POINTS-DEFICIT-1); this says the
losses themselves: the posted sales and customer purchases of the period whose
cash profit is below nothing, each its employee by the points' own attribution
(PointsMetric._infer_actor -- a return is its sale's). Nothing here writes.
"""
from __future__ import annotations

from datetime import datetime

LOSS = -0.005


def deficits(start: datetime, end: datetime) -> dict:
    from metrics.points_metric import PointsMetric
    from models import Invoice

    rows = (Invoice.query
            .filter(Invoice.is_posted.is_(True), Invoice.invoice_type.in_(['بيع', 'شراء من عميل']),
                    Invoice.date >= start, Invoice.date < end, Invoice.profit_cash < LOSS)
            .order_by(Invoice.date).all())
    by_actor: dict = {}
    for inv in rows:
        actor_id, name = PointsMetric._infer_actor(inv) or (0, '—')
        e = by_actor.setdefault(actor_id, {'id': actor_id, 'name': name, 'count': 0, 'loss_cash': 0.0})
        e['count'] += 1
        e['loss_cash'] += float(inv.profit_cash or 0.0)
    employees = sorted(({**e, 'loss_cash': round(e['loss_cash'], 2)} for e in by_actor.values()),
                       key=lambda e: e['loss_cash'])
    return {'start': start.date().isoformat(), 'count': len(rows),
            'loss_cash': round(sum(e['loss_cash'] for e in employees), 2), 'employees': employees}
