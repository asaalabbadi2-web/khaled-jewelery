"""A personal goal's achievement: decided by the server, on the one measure, for what its rule pays (bonus study م1).

The owner (24 Oct 2026): «ابدأ واعتمد توصياتك» -- a personal goal is a rule
for one employee, its achievement its bonus. It was decided in the route the
app called when it opened (`goal-check`): August and September 2026 had their
bonuses and no achievement recorded. It counted Σprofit_gold × 10 where the
race and the bonus count the race's points (May: 1,032.5 against 1,223), aimed
at the employee's own target (999.9) beside its rule's threshold (1,000), and
promised actual × the rule's value -- not what the rule pays.

Here:
  goal_performance  the employee's measure (services/performance_measures);
  goal_target       a goal paid by a rule aims at the rule's threshold;
  goal_amount       what the rule pays for the period so far
                    (BonusCalculator.estimate), else the goal's fixed amount;
  record_goal_achievements(today, now[, employee])
                    called by the daily run for everyone, and by goal-check
                    for one -- the app's call no longer decides what happened.
  period_key_for    a bonus's period as an achievement's key: the month's
                    bonus takes its goal's achievement as its own.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta

PERIODS = (('daily', 'اليومي'), ('weekly', 'الأسبوعي'), ('monthly', 'الشهري'))
METRIC_MEASURES = {'points': 'points', 'weight': 'sold_weight', 'invoices': 'count'}


def period_key(period_name: str, day: date) -> str:
    """daily-YYYY-MM-DD | weekly-YYYY-W## | monthly-YYYY-MM."""
    if period_name == 'daily':
        return f'daily-{day.isoformat()}'
    if period_name == 'weekly':
        iso = day.isocalendar()
        return f'weekly-{iso[0]}-W{iso[1]:02d}'
    return f'monthly-{day.year}-{day.month:02d}'


def period_key_for(start: date, end: date) -> str | None:
    """A bonus's period as a goal's key, when it is one of the goals' periods."""
    if start == end:
        return period_key('daily', start)
    if (end - start).days == 6 and start.weekday() == 0:
        return period_key('weekly', start)
    if start.day == 1 and (end + timedelta(days=1)).day == 1 and start.month == end.month:
        return period_key('monthly', start)
    return None


def _bounds(period_name: str, today: date):
    if period_name == 'daily':
        return today, today
    if period_name == 'weekly':
        return today - timedelta(days=today.weekday()), today
    return today.replace(day=1), today


def goal_rule(employee, period_name):
    from models import BonusRule
    if (getattr(employee, f'goal_reward_type_{period_name}', None) or 'fixed') != 'rule':
        return None
    rule_id = getattr(employee, f'goal_bonus_rule_id_{period_name}', None)
    return BonusRule.query.get(rule_id) if rule_id else None


def goal_performance(employee, metric: str, start, end) -> float:
    from services.performance_measures import measure
    return measure(METRIC_MEASURES.get(metric, 'sold_weight'), employee.id, start, end)


def goal_target(employee, period_name: str, metric: str):
    """A goal paid by a rule aims at the rule's threshold -- a tiered rule's
    first tier, a points rule's min_points -- one number, not the employee's
    beside it (999.9 and 1,000)."""
    rule = goal_rule(employee, period_name)
    if rule is not None and rule.rule_type == 'tiered' and rule.tiers \
            and METRIC_MEASURES.get(metric) == rule.measure:
        return float(rule.tiers[0]['from'])                 # the first tier is the goal (م2)
    if rule is not None and rule.rule_type == 'points_based' and metric == 'points':
        threshold = (rule.conditions or {}).get('min_points')
        if threshold:
            return float(threshold)
    field = {'weight': 'goal_weight', 'points': 'goal_points', 'invoices': 'goal_invoices'}.get(metric, 'goal_weight')
    return getattr(employee, f'{field}_{period_name}', None)


def goal_amount(employee, period_name: str, start, end) -> float:
    rule = goal_rule(employee, period_name)
    if rule is not None:
        from bonus_calculator import BonusCalculator
        return BonusCalculator.estimate(employee, rule, start, end)
    return float(getattr(employee, f'goal_bonus_{period_name}', None) or 0.0)


def _existing(employee_id: int, key: str):
    from models import GoalAchievement
    found = GoalAchievement.query.filter_by(employee_id=employee_id, period_key=key).first()
    if found is not None:
        return found
    for old in GoalAchievement.query.filter_by(employee_id=employee_id).all():      # older rows: the key in metrics
        if isinstance(old.metrics, dict) and old.metrics.get('period_key') == key:
            return old
    return None


def record_goal_achievements(today: date, now: datetime, employee=None) -> list:
    """Each enabled goal reached in its period so far, recorded once at *now*.
    Returns what was recorded."""
    from models import Employee, GoalAchievement, db
    employees = [employee] if employee is not None else Employee.query.filter_by(is_active=True).all()
    recorded = []
    for emp in employees:
        metric = emp.goal_metric or 'weight'
        for period_name, label in PERIODS:
            if not getattr(emp, f'goal_{period_name}_enabled', False):
                continue
            target = goal_target(emp, period_name, metric)
            if target is None or float(target) <= 0:
                continue
            key = period_key(period_name, today)
            if _existing(emp.id, key) is not None:
                continue
            start, end = _bounds(period_name, today)
            actual = goal_performance(emp, metric, start, end)
            if actual < float(target):
                continue
            rule = goal_rule(emp, period_name)
            achievement = GoalAchievement(
                employee_id=emp.id, bonus_rule_id=rule.id if rule is not None else None,
                goal_name=emp.goal_name or f'هدف {label}',
                goal_description=f'تحقيق هدف {label}: {actual:.1f} / {float(target):.1f}',
                bonus_amount=round(goal_amount(emp, period_name, start, end), 2), currency='SAR',
                metrics={'period': period_name, 'actual': round(actual, 2), 'target': round(float(target), 2),
                         'metric': metric},
                period_key=key, goal_period=period_name, achieved_at=now)
            db.session.add(achievement)
            db.session.flush()
            recorded.append(achievement)
    return recorded
