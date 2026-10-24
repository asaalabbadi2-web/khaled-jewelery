"""«هدفي»: what the signed-in employee is told about their goal is what will be paid (bonus study م3).

The owner (24 Oct 2026): «ابدأ واعتمد توصياتك» -- the employee sees one
number. The server says it, from the one measure (ADR-058): the period's
value so far, the goal's target (its rule's threshold), what its rule pays so
far, and how far the next tier is.

Run:
    python -m pytest tests/test_my_goal.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, BonusRule, Employee, Invoice, InvoiceItem, Settings, db

TODAY = date.today()


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0})
    db.session.flush()
    yield


def _tiered(tiers):
    rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers', bonus_value=0.0,
                     min_bonus=0.0, is_active=True, measure='points', period='monthly', tiers=tiers)
    db.session.add(rule)
    db.session.flush()
    return rule


def _employee(rule=None):
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'G{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    if rule is not None:
        emp.goal_metric, emp.goal_monthly_enabled, emp.goal_points_monthly = 'points', True, 5000.0
        emp.goal_reward_type_monthly, emp.goal_bonus_rule_id_monthly = 'rule', rule.id
    db.session.add(emp)
    db.session.flush()
    user = AppUser(username=f'g{uuid.uuid4().hex[:8]}', employee_id=emp.id, role='employee', is_active=True,
                   password_hash='x')
    db.session.add(user)
    db.session.flush()
    return emp, user


def _sale(emp, points):
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8,
                  date=datetime.combine(TODAY.replace(day=1), datetime.min.time()).replace(hour=10),
                  total=10000.0, total_tax=0.0, is_posted=True, status='paid', employee_id=emp.id,
                  profit_cash=points * 50.0, total_weight=10.0)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=10000.0, karat=21.0, weight=10.0))
    db.session.flush()


def _progress(user):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/achievements/progress',
                                       headers={'Authorization': f'Bearer {generate_token(user)}'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()['goals']


def test_the_goal_says_its_value_its_rule_s_target_what_it_pays_and_the_next_tier():
    emp, user = _employee(_tiered([{'from': 1000, 'per_unit': 2.5}, {'from': 1500, 'per_unit': 3.0}]))
    _sale(emp, 1200)
    (goal,) = _progress(user)
    assert goal['period'] == 'monthly' and goal['metric'] == 'points'
    assert (goal['value'], goal['target'], goal['reached']) == (1200, 1000.0, True)
    assert goal['amount_so_far'] == pytest.approx(3000.0)
    assert goal['tier']['from'] == 1000 and goal['next_tier']['from'] == 1500
    assert goal['to_next'] == pytest.approx(300)


def test_below_the_first_tier_it_says_how_far_and_pays_nothing_yet():
    emp, user = _employee(_tiered([{'from': 1000, 'per_unit': 2.5}]))
    _sale(emp, 700)
    (goal,) = _progress(user)
    assert (goal['reached'], goal['amount_so_far'], goal['tier']) == (False, 0.0, None)
    assert goal['next_tier']['from'] == 1000 and goal['to_next'] == pytest.approx(300)
    assert goal['progress'] == pytest.approx(0.7)


def test_no_goal_says_none():
    _, user = _employee()
    assert _progress(user) == []
