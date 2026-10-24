"""The months an employee led the race, and the periods they reached their goal (bonus study م3هـ).

Kept in `race_honour` once each period closes (the owner, 24 Oct 2026: «سجل
محفوظ»), so the race card's crown and target counters read what was, not what
today's settings would make of it:

- a month's leader by points («الأشهر دائمًا»); a tie at the top crowns each;
- a closed period of the employee's own goal -- daily, weekly or monthly --
  whose value reached its target, by the measure and target that pay it
  (ADR-058; «فترات هدفه التي بلغها»).

`record_closed` records the latest closed day, week and month (the daily run);
`backfill` walks the past period by period. Both write a period once.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta

from services.goal_achievements import PERIODS, goal_performance, goal_target


def closed_periods(today: date) -> list[tuple[str, date, date]]:
    """The latest closed day, week (Monday to Sunday) and month before *today*."""
    yesterday = today - timedelta(days=1)
    week_end = today - timedelta(days=today.weekday() + 1)
    month_end = today.replace(day=1) - timedelta(days=1)
    return [('daily', yesterday, yesterday), ('weekly', week_end - timedelta(days=6), week_end),
            ('monthly', month_end.replace(day=1), month_end)]


def _kept(employee_id: int, kind: str, period: str, start: date) -> bool:
    from models import RaceHonour
    return RaceHonour.query.filter_by(employee_id=employee_id, kind=kind, period=period,
                                      period_start=start).first() is not None


def _keep(employee_id, kind, period, start, end, value, target, now) -> object | None:
    from models import RaceHonour, db
    if _kept(employee_id, kind, period, start):
        return None
    honour = RaceHonour(employee_id=employee_id, kind=kind, period=period, period_start=start, period_end=end,
                        value=value, target=target, recorded_at=now)
    db.session.add(honour)
    db.session.flush()
    return honour


def _leaders(start: date, end: date, now: datetime) -> list:
    from models import Employee
    from services.performance_measures import measure
    points = {emp.id: int(round(measure('points', emp.id, start, end))) for emp in Employee.query.all()}
    top = max(points.values(), default=0)
    if top <= 0:
        return []
    return [kept for emp_id, value in points.items() if value == top
            if (kept := _keep(emp_id, 'leader', 'monthly', start, end, value, None, now)) is not None]


def _goals(period: str, start: date, end: date, now: datetime) -> list:
    from models import Employee
    from services.goal_achievements import goal_rule
    kept = []
    for emp in Employee.query.filter(getattr(Employee, f'goal_{period}_enabled').is_(True)).all():
        metric = emp.goal_metric or 'weight'
        target = goal_target(emp, period, metric)
        if target is None or float(target) <= 0 or _kept(emp.id, 'goal', period, start):
            continue
        # A goal paid by a rule is no goal before or after the rule's validity.
        rule = goal_rule(emp, period)
        if rule is not None and rule.valid_window(start, end) is None:
            continue
        value = goal_performance(emp, metric, start, end)
        if metric == 'points':
            value = int(round(value))
        if value >= float(target) and (honour := _keep(emp.id, 'goal', period, start, end, value,
                                                         float(target), now)) is not None:
            kept.append(honour)
    return kept


def record_period(period: str, start: date, end: date, now: datetime) -> list:
    """A closed period's honours: its goals reached, and a month's leaders."""
    kept = _goals(period, start, end, now)
    if period == 'monthly':
        kept += _leaders(start, end, now)
    return kept


def record_closed(today: date, now: datetime) -> list:
    """The latest closed day, week and month, each once."""
    kept = []
    for period, start, end in closed_periods(today):
        kept += record_period(period, start, end, now)
    return kept


def backfill(since: date, today: date, now: datetime) -> list:
    """Every period closed from *since* until *today*, each once. A goal's past
    periods are measured against its target as it is now: its earlier targets
    were not kept."""
    kept = []
    day = since
    while day < today:
        kept += record_period('daily', day, day, now)
        if day.weekday() == 6 and day - timedelta(days=6) >= since:
            kept += record_period('weekly', day - timedelta(days=6), day, now)
        if (day + timedelta(days=1)).day == 1 and day.replace(day=1) >= since:
            kept += record_period('monthly', day.replace(day=1), day, now)
        day += timedelta(days=1)
    return kept


def honours_of(employee_ids) -> dict:
    """{employee_id: {'crowns': months led, 'goals_reached': goal periods reached}}."""
    from sqlalchemy import func

    from models import RaceHonour, db
    ids = [i for i in employee_ids if i is not None]
    if not ids:
        return {}
    counts = {i: {'crowns': 0, 'goals_reached': 0} for i in ids}
    rows = (db.session.query(RaceHonour.employee_id, RaceHonour.kind, func.count(RaceHonour.id))
            .filter(RaceHonour.employee_id.in_(ids)).group_by(RaceHonour.employee_id, RaceHonour.kind).all())
    for emp_id, kind, n in rows:
        counts[emp_id]['crowns' if kind == 'leader' else 'goals_reached'] = int(n)
    return counts


__all__ = ['PERIODS', 'backfill', 'closed_periods', 'honours_of', 'record_closed', 'record_period']
