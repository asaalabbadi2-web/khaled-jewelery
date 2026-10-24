"""The race, the goals and the bonuses read one measure (bonus study م1).

The owner (24 Oct 2026): «ابدأ واعتمد توصياتك» -- a personal goal is a rule
for one employee, its achievement is its bonus. They measured the same
employee three ways: the race by the points engine; the bonuses by it for
points but by their own sums for sales and profit, crediting the seller *or*
the poster; the goals by Σprofit_gold × 10. On the 23 Oct copy a goal showed
مسعد 1,032.5 points and 2,581 riyals for May, and his bonus paid 1,223 points,
3,057.5 riyals -- and an achievement was recorded only when the app called.

One measure (services/performance_measures): an invoice is its seller's, or
its poster's when it has none; a return takes back its share and a correction
its difference, in their own period; points by the race's settings. The goal
reads it, aims at its rule's threshold, promises what its rule pays, and is
recorded by the server; the month's bonus takes the goal's achievement as its
own.

Run:
    python -m pytest tests/test_one_measure.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest

from models import (AppUser, BonusRule, Employee, EmployeeBonus, GoalAchievement, Invoice, InvoiceItem, Settings,
                    db)

TODAY = date(2031, 5, 20)
NOW = datetime(2031, 5, 20, 21, 0)
MAY = (date(2031, 5, 1), date(2031, 5, 31))


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0})
    db.session.flush()
    yield


def _employee(goal=False, rule=None):
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'M{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    if goal:
        emp.goal_metric, emp.goal_monthly_enabled, emp.goal_points_monthly = 'points', True, 5000.0
        emp.goal_reward_type_monthly, emp.goal_bonus_rule_id_monthly = 'rule', rule.id
    db.session.add(emp)
    db.session.flush()
    user = AppUser(username=f'u{uuid.uuid4().hex[:8]}', employee_id=emp.id, role='employee', is_active=True,
                   password_hash='x')
    db.session.add(user)
    db.session.flush()
    return emp, user.username


def _sale(seller, poster, when, *, profit_cash=5000.0, total=10000.0, grams=10.0, profit_gold=2.0):
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=when, total=total,
                  total_tax=0.0, is_posted=True, status='paid', employee_id=seller, posted_by=poster,
                  profit_cash=profit_cash, profit_gold=profit_gold, total_weight=grams)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=total, karat=21.0, weight=grams))
    db.session.flush()
    return inv


def _return(original, when, share):
    ret = Invoice(invoice_type='مرتجع بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=when,
                  total=original.total * share, total_tax=0.0, is_posted=True, status='paid',
                  original_invoice_id=original.id, total_weight=original.total_weight * share)
    db.session.add(ret)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=ret.id, name='سلسال', quantity=1, price=ret.total, karat=21.0,
                               weight=original.total_weight * share))
    db.session.flush()
    return ret


def _points_rule(min_points=1000.0, per_point=2.5):
    rule = BonusRule(name=f'شهري {uuid.uuid4().hex[:6]}', rule_type='points_based', bonus_type='points_per_unit',
                     bonus_value=per_point, min_bonus=0.0, is_active=True,
                     conditions={'min_points': min_points, 'points_period': 'month'})
    db.session.add(rule)
    db.session.flush()
    return rule


# ── one attribution ───────────────────────────────────────────────────────

def test_a_sale_is_its_seller_s_not_its_poster_s():
    from bonus_calculator import BonusCalculator
    from services.performance_measures import measure
    seller, _ = _employee()
    poster, poster_name = _employee()
    _sale(seller.id, poster_name, datetime(2031, 5, 3, 10))
    assert measure('points', seller.id, *MAY) == pytest.approx(100.0)
    assert measure('points', poster.id, *MAY) == pytest.approx(0.0)
    assert BonusCalculator.calculate_points_bonus(poster, _points_rule(min_points=1.0), *MAY) is None


def test_a_sale_with_no_seller_is_its_poster_s():
    from services.performance_measures import measure
    poster, poster_name = _employee()
    _sale(None, poster_name, datetime(2031, 5, 3, 10))
    assert measure('points', poster.id, *MAY) == pytest.approx(100.0)


# ── returns, in their own period ──────────────────────────────────────────

def test_a_return_takes_back_its_share_of_the_sales_bonus():
    from bonus_calculator import BonusCalculator
    from services.performance_measures import measure
    seller, _ = _employee()
    sale = _sale(seller.id, None, datetime(2031, 5, 3, 10))
    _return(sale, datetime(2031, 5, 10, 10), 0.5)
    assert measure('sales', seller.id, *MAY) == pytest.approx(5000.0)
    rule = BonusRule(name='مبيعات', rule_type='sales_target', bonus_type='sales_percentage', bonus_value=10.0,
                     min_bonus=0.0, is_active=True, conditions={'sales_target': 0})
    db.session.add(rule)
    db.session.flush()
    _, amount, data, _, _ = BonusCalculator.calculate_sales_bonus(seller, rule, *MAY)
    assert (data['sales_amount'], amount) == (pytest.approx(5000.0), pytest.approx(500.0))


# ── the goal reads it, aims at its rule, promises what its rule pays ──────

def test_the_goal_reads_the_points_the_bonus_pays():
    from bonus_calculator import BonusCalculator
    from services.goal_achievements import goal_performance
    rule = _points_rule()
    emp, _ = _employee(goal=True, rule=rule)
    _sale(emp.id, None, datetime(2031, 5, 3, 10), profit_cash=60000.0, profit_gold=20.0)   # 1,200 points
    assert goal_performance(emp, 'points', *MAY) == pytest.approx(1200.0)
    _, amount, data, _, _ = BonusCalculator.calculate_points_bonus(emp, rule, *MAY)
    assert data['employee_points'] == 1200


def test_the_server_records_the_goal_at_its_rule_s_threshold_with_what_the_rule_pays():
    from services.goal_achievements import record_goal_achievements
    rule = _points_rule()
    emp, _ = _employee(goal=True, rule=rule)                 # its own target 5,000: the rule's is 1,000
    _sale(emp.id, None, datetime(2031, 5, 3, 10), profit_cash=60000.0)
    record_goal_achievements(TODAY, NOW)
    (got,) = GoalAchievement.query.filter_by(employee_id=emp.id).all()
    assert got.period_key == 'monthly-2031-05'
    assert got.bonus_amount == pytest.approx(1200 * 2.5)
    assert got.metrics['target'] == pytest.approx(1000.0)
    record_goal_achievements(TODAY, NOW)
    assert GoalAchievement.query.filter_by(employee_id=emp.id).count() == 1


def test_the_daily_run_records_the_goals(monkeypatch):
    from app import app as flask_app
    from bonus_scheduler import BonusScheduler
    from bonus_calculator import BonusCalculator
    seen = []
    monkeypatch.setattr(BonusCalculator, 'calculate_all_bonuses_for_period', staticmethod(lambda *a, **k: []))
    monkeypatch.setattr('bonus_scheduler._write_log', lambda *a, **k: None)
    monkeypatch.setattr('services.goal_achievements.record_goal_achievements', lambda today, now: seen.append(today))
    BonusScheduler(flask_app).calculate_daily_bonuses()
    assert len(seen) == 1


def test_the_month_s_bonus_takes_its_goal_s_achievement_not_a_second():
    from bonus_routes import _create_achievement_for_bonus
    from services.goal_achievements import record_goal_achievements
    rule = _points_rule()
    emp, _ = _employee(goal=True, rule=rule)
    _sale(emp.id, None, datetime(2031, 5, 3, 10), profit_cash=60000.0)
    record_goal_achievements(TODAY, NOW)
    bonus = EmployeeBonus(employee_id=emp.id, bonus_rule_id=rule.id, bonus_type='points_based', amount=3500.0,
                          status='approved', period_start=MAY[0], period_end=MAY[1])
    db.session.add(bonus)
    db.session.flush()
    _create_achievement_for_bonus(bonus, emp)
    db.session.flush()
    (got,) = GoalAchievement.query.filter_by(employee_id=emp.id).all()
    assert (got.bonus_id, got.bonus_amount) == (bonus.id, pytest.approx(3500.0))


def test_the_home_screen_s_check_records_the_goal_by_the_one_measure():
    """The home screen calls /achievements/check-progress on every return --
    not goal-check: it was a fourth count (the seller or the poster, the
    employee's own target, actual × the rule's value), the one the app shows.
    It records by the one measure, at the rule's threshold, for what it pays."""
    from flask import g

    from app import app as flask_app
    from auth_decorators import generate_token
    rule = _points_rule()
    emp, username = _employee(goal=True, rule=rule)             # its own target 5,000: the rule's is 1,000
    _sale(emp.id, None, datetime.now().replace(day=1, hour=10), profit_cash=60000.0)
    user = AppUser.query.filter_by(username=username).one()
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/achievements/check-progress',
                                        headers={'Authorization': f'Bearer {generate_token(user)}'}, json={})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    (shown,) = resp.get_json()['achievements']
    assert shown['bonus_amount'] == pytest.approx(1200 * 2.5)
    (got,) = GoalAchievement.query.filter_by(employee_id=emp.id).all()
    assert got.metrics['target'] == pytest.approx(1000.0)


def test_the_race_s_goal_ring_aims_at_the_rule_s_threshold(auth_headers):
    """The ring round an employee's photo on the race measured the period's
    score against the employee's own target (999.9), not the threshold its
    rule pays at (1,000): one goal, one number."""
    from flask import g

    from app import app as flask_app
    rule = _points_rule()
    emp, _ = _employee(goal=True, rule=rule)                 # its own target 5,000
    _sale(emp.id, None, datetime.now().replace(hour=9, minute=0), profit_cash=60000.0)
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/home/leaderboard?period=month&metric=points', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    (row,) = [r for r in resp.get_json()['ranking'] if r['id'] == emp.id]
    assert row['goal_target'] == pytest.approx(1000.0)
