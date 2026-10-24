"""The team's monthly goal is the sum of its employees' monthly goals, by the one measure (bonus study م3ح).

The owner (24 Oct 2026): one team goal, monthly, a ring like «هدفي», the
weekly one gone; its figure «مجموع أهداف الموظفين». It was a weight in the
settings (125 g a week, 500 g a month) turned into points by the points per
gram -- 5,000 «points» that meant nothing where points are made of profit --
and its percent came from the weight while the card showed points. Now: the
employees with a monthly goal, their targets summed, their values this month
summed, each by the measure and target that pay it (ADR-058).

Run:
    python -m pytest tests/test_team_goal.py -v
"""
import json
import uuid
from datetime import date, datetime, time

import pytest
from flask import g

from app import app as flask_app
from models import BonusRule, Employee, Invoice, InvoiceItem, Settings, db

TODAY = date.today()


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0})
    # Every employee in the fence goes off the team but ours.
    Employee.query.update({Employee.goal_monthly_enabled: False})
    db.session.flush()
    yield


def _employee(goal=None):
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'T{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    if goal is not None:
        rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers',
                         bonus_value=0.0, min_bonus=0.0, is_active=True, measure='points', period='monthly',
                         tiers=[{'from': goal, 'per_unit': 2.5}])
        db.session.add(rule)
        db.session.flush()
        emp.goal_metric, emp.goal_monthly_enabled, emp.goal_points_monthly = 'points', True, float(goal)
        emp.goal_reward_type_monthly, emp.goal_bonus_rule_id_monthly = 'rule', rule.id
    db.session.add(emp)
    db.session.flush()
    return emp


def _sale(emp, points):
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8,
                  date=datetime.combine(TODAY, time(10)), total=10000.0, total_tax=0.0, is_posted=True,
                  status='paid', employee_id=emp.id, profit_cash=points * 50.0, total_weight=10.0)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=10000.0, karat=21.0, weight=10.0))
    db.session.flush()


def test_the_team_goal_sums_the_employees_goals_and_their_values():
    from services.goal_achievements import team_goal
    a, b, outside = _employee(goal=1000), _employee(goal=800), _employee()
    _sale(a, 1200)
    _sale(b, 300)
    _sale(outside, 5000)
    goal = team_goal(TODAY)
    assert (goal['metric'], goal['period'], goal['employees']) == ('points', 'monthly', 2)
    assert (goal['target'], goal['value']) == (1800, 1500), 'the employee without a goal is in neither'
    assert goal['progress'] == pytest.approx(1500 / 1800, abs=1e-4)
    assert goal['reached'] is False


def test_no_monthly_goal_no_team_goal():
    from services.goal_achievements import team_goal
    _employee()
    assert team_goal(TODAY) is None


def _race(headers, period):
    g.pop('current_user', None)
    resp = flask_app.test_client().get(f'/api/home/leaderboard?period={period}&metric=points', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_the_race_carries_the_team_goal_in_the_month_s_view_and_no_weekly_one(auth_headers):
    """The owner: the month is where the employee looks to see where they are;
    the goals are shown there."""
    a = _employee(goal=1000)
    _sale(a, 1200)
    body = _race(auth_headers, 'month')
    assert (body['team_goal']['target'], body['team_goal']['value']) == (1000, 1200)
    assert 'weekly_target_points' not in body and 'weekly_target_weight_g' not in body
    assert _race(auth_headers, 'today')['team_goal'] is None


def test_the_week_s_team_goal_is_the_week_s_share_of_the_monthly_one(auth_headers):
    """The owner: «من نقاط الموظفين الشهري مقسمًا على عدد الأسابيع» -- the
    monthly target times 7 over the month's days, against the week's points."""
    from calendar import monthrange
    a, b = _employee(goal=1000), _employee(goal=800)
    _sale(a, 120)
    _sale(b, 30)
    week = _race(auth_headers, 'week')['team_goal']
    days = monthrange(TODAY.year, TODAY.month)[1]
    assert (week['period'], week['unit'], week['share_of']) == ('weekly', 'نقطة', 'monthly')
    assert week['target'] == round(1800 * 7 / days)
    assert week['value'] == 150

def test_everyone_sees_the_team_goal_where_the_team_summary_is_the_manager_s():
    """The owner: «الجميع دائمًا» -- the team summary's money stays the
    manager's; the team's goal, in points or grams, is everyone's."""
    from models import AppUser
    from auth_decorators import generate_token
    settings = Settings.query.first()
    cfg = json.loads(settings.sales_race_settings)
    cfg['period_visibility'] = {'month': {'team_summary': 'admin_only'}}
    settings.sales_race_settings = json.dumps(cfg)
    a = _employee(goal=1000)
    _sale(a, 1200)
    seller = AppUser(username=f't{uuid.uuid4().hex[:8]}', employee_id=a.id, role='employee', is_active=True,
                     password_hash='x')
    db.session.add(seller)
    db.session.flush()
    body = _race({'Authorization': f'Bearer {generate_token(seller)}'}, 'month')
    assert (body['team_goal']['target'], body['team_goal']['value']) == (1000, 1200)
    assert body.get('admin_summary') is None, 'the summary stays the manager\'s'


def test_the_team_goal_in_points_is_not_said_where_the_points_are_the_manager_s():
    from models import AppUser
    from auth_decorators import generate_token
    settings = Settings.query.first()
    cfg = json.loads(settings.sales_race_settings)
    cfg['period_visibility'] = {'month': {'points': 'admin_only'}}
    settings.sales_race_settings = json.dumps(cfg)
    a = _employee(goal=1000)
    _sale(a, 1200)
    seller = AppUser(username=f't{uuid.uuid4().hex[:8]}', employee_id=a.id, role='employee', is_active=True,
                     password_hash='x')
    db.session.add(seller)
    db.session.flush()
    assert _race({'Authorization': f'Bearer {generate_token(seller)}'}, 'month')['team_goal'] is None
