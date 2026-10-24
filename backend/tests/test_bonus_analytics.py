"""The bonus analytics say what was granted, from the server (bonus study م3و).

The analytics page summed every bonus it loaded, whatever its state: a
rejected bonus counted as given, a pending one as spent; «last year» was every
bonus ever; and the page computed it all itself. Now one route answers, by
the bonus's period: what was granted (approved and paid -- what the books
carry), by employee, by rule, by month and by department; what waits pending,
apart; and how many of each state. A rejected or reversed bonus is in no
amount.

Run:
    python -m pytest tests/test_bonus_analytics.py -v
"""
import uuid
from datetime import date

import pytest
from flask import g

from app import app as flask_app
from models import BonusRule, Employee, EmployeeBonus, db


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _employee(department):
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'A{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0, department=department)
    db.session.add(emp)
    db.session.flush()
    return emp


def _bonus(emp, rule, amount, status, month):
    start = date(2031, month, 1)
    end = date(2031, month, 28)
    db.session.add(EmployeeBonus(employee_id=emp.id, bonus_rule_id=rule.id if rule else None, bonus_type='tiers',
                                 amount=amount, status=status, period_start=start, period_end=end))
    db.session.flush()


def _analytics(headers, **params):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/bonuses/analytics', headers=headers,
                                       query_string={'from': '2031-01-01', 'to': '2031-12-31', **params})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


@pytest.fixture
def ledger():
    rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers', bonus_value=0.0,
                     min_bonus=0.0, is_active=True, measure='points', period='monthly',
                     tiers=[{'from': 1000, 'per_unit': 2.5}])
    db.session.add(rule)
    db.session.flush()
    sales, office = f'مبيعات {uuid.uuid4().hex[:4]}', f'مكتب {uuid.uuid4().hex[:4]}'
    a, b = _employee(sales), _employee(office)
    _bonus(a, rule, 3000.0, 'paid', 5)
    _bonus(a, rule, 2500.0, 'approved', 6)
    _bonus(a, rule, 9999.0, 'rejected', 6)
    _bonus(b, None, 400.0, 'paid', 6)
    _bonus(b, rule, 700.0, 'pending', 7)
    _bonus(b, rule, 800.0, 'reversed', 7)
    return {'rule': rule, 'a': a, 'b': b, 'sales': sales, 'office': office}


def test_granted_is_approved_and_paid_alone_and_pending_waits_apart(auth_headers, ledger):
    body = _analytics(auth_headers)
    assert body['granted_total'] == pytest.approx(5900.0)
    assert body['pending_total'] == pytest.approx(700.0)
    assert body['statuses'] == {'pending': 1, 'approved': 1, 'paid': 2, 'rejected': 1, 'reversed': 1}
    assert body['approval_rate'] == pytest.approx(0.75), '3 granted of 4 decided'


def test_by_employee_by_rule_by_month_and_by_department(auth_headers, ledger):
    body = _analytics(auth_headers)
    employees = {r['employee_id']: r for r in body['by_employee']}
    assert employees[ledger['a'].id]['amount'] == pytest.approx(5500.0)
    assert employees[ledger['b'].id]['amount'] == pytest.approx(400.0)
    assert body['by_employee'][0]['employee_id'] == ledger['a'].id, 'highest first'
    rules = {r['name']: r['amount'] for r in body['by_rule']}
    assert {r['name']: r['share'] for r in body['by_rule']}['يدوية'] == pytest.approx(400 / 5900, abs=1e-4)
    assert rules[ledger['rule'].name] == pytest.approx(5500.0)
    assert rules['يدوية'] == pytest.approx(400.0)
    months = {r['month']: r['amount'] for r in body['by_month']}
    assert (months['2031-05'], months['2031-06'], months['2031-07']) == (3000.0, 2900.0, 0.0)
    departments = {r['department']: r for r in body['by_department']}
    assert departments[ledger['sales']]['amount'] == pytest.approx(5500.0)
    assert departments[ledger['sales']]['employees'] == 1


def test_the_window_is_the_bonus_s_period(auth_headers, ledger):
    body = _analytics(auth_headers, **{'from': '2031-06-01', 'to': '2031-06-30'})
    assert body['granted_total'] == pytest.approx(2900.0)
    assert [r['month'] for r in body['by_month']] == ['2031-06']


def test_an_unreadable_window_is_refused(auth_headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/bonuses/analytics', headers=auth_headers,
                                       query_string={'from': 'أمس', 'to': '2031-12-31'})
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invalid_window'
