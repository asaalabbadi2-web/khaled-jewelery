"""A rule's page says what the rule does, and keeps what it did (bonus study م3ج).

- A rule with bonuses, or that is an employee's goal, is not deleted: its
  bonuses keep their rule, and their history its name. Deleting it answered
  with the database's own words; it says now to stop it instead.
- A validity date set once can be cleared: the form sent none, and the
  route kept the old one.
- The rule says its employees by name: the page showed «#16».

Run:
    python -m pytest tests/test_bonus_rules_screen.py -v
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


def _rule(**kw):
    rule = BonusRule(name=f'قاعدة {uuid.uuid4().hex[:6]}', rule_type='fixed', bonus_type='fixed', bonus_value=100.0,
                     min_bonus=0.0, is_active=True, **kw)
    db.session.add(rule)
    db.session.flush()
    return rule


def _employee(**kw):
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'R{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0, **kw)
    db.session.add(emp)
    db.session.flush()
    return emp


def _client():
    g.pop('current_user', None)
    return flask_app.test_client()


def test_a_rule_with_bonuses_is_stopped_not_deleted(auth_headers):
    rule = _rule()
    emp = _employee()
    db.session.add(EmployeeBonus(employee_id=emp.id, bonus_rule_id=rule.id, bonus_type='fixed', amount=100.0,
                                 status='paid', period_start=date(2031, 5, 1), period_end=date(2031, 5, 31)))
    db.session.flush()
    resp = _client().delete(f'/api/bonus-rules/{rule.id}', headers=auth_headers)
    assert resp.status_code == 409, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'rule_in_use' and body['bonuses'] == 1
    assert 'أوقفها' in body['message']
    assert db.session.get(BonusRule, rule.id) is not None


def test_a_rule_that_is_an_employee_s_goal_is_not_deleted(auth_headers):
    rule = _rule()
    _employee(goal_bonus_rule_id_monthly=rule.id)
    resp = _client().delete(f'/api/bonus-rules/{rule.id}', headers=auth_headers)
    assert resp.status_code == 409
    assert resp.get_json()['goals'] == 1


def test_an_unused_rule_is_deleted(auth_headers):
    rule = _rule()
    resp = _client().delete(f'/api/bonus-rules/{rule.id}', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert db.session.get(BonusRule, rule.id) is None


def test_a_validity_date_set_once_can_be_cleared(auth_headers):
    rule = _rule(valid_from=date(2031, 1, 1), valid_to=date(2031, 12, 31))
    resp = _client().put(f'/api/bonus-rules/{rule.id}', headers=auth_headers,
                         json={'valid_from': None, 'valid_to': None})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.refresh(rule)
    assert (rule.valid_from, rule.valid_to) == (None, None)


def test_a_rule_says_its_employees_by_name(auth_headers):
    emp = _employee()
    rule = _rule(target_employee_ids=[emp.id])
    resp = _client().get(f'/api/bonus-rules/{rule.id}', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    found = body.get('rule', body)
    assert found['target_employees'] == [{'id': emp.id, 'name': emp.name}]
