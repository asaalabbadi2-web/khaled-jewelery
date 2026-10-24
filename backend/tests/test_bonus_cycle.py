"""A bonus a rule computed is the rule's: its amount and period are not typed over (bonus study م3ب).

The pending bonus is recomputed from its rule by the next run (ADR-058 §2):
an amount typed over it was undone unsaid; and its period typed over moved it
off its (employee, rule, period) -- the next run of the period made it again,
two bonuses for one month's work. A note stays the manager's. To pay another
amount: reject it, and add a bonus by hand with its reason.

Run:
    python -m pytest tests/test_bonus_cycle.py -v
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


def _bonus(with_rule=True):
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'C{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    db.session.add(emp)
    db.session.flush()
    rule = None
    if with_rule:
        rule = BonusRule(name=f'قاعدة {uuid.uuid4().hex[:6]}', rule_type='fixed', bonus_type='fixed',
                         bonus_value=100.0, min_bonus=0.0, is_active=True)
        db.session.add(rule)
        db.session.flush()
    bonus = EmployeeBonus(employee_id=emp.id, bonus_rule_id=rule.id if rule else None, bonus_type='fixed',
                          amount=100.0, status='pending', period_start=date(2031, 5, 1), period_end=date(2031, 5, 31))
    db.session.add(bonus)
    db.session.flush()
    return bonus


def _put(headers, bonus, body):
    g.pop('current_user', None)
    return flask_app.test_client().put(f'/api/bonuses/{bonus.id}', headers=headers, json=body)


@pytest.mark.parametrize('body', [{'amount': 999.0}, {'period_start': '2031-04-01'}, {'period_end': '2031-06-30'}])
def test_a_rule_s_bonus_is_not_typed_over(auth_headers, body):
    bonus = _bonus()
    resp = _put(auth_headers, bonus, body)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'computed_by_rule'
    db.session.refresh(bonus)
    assert (bonus.amount, bonus.period_start) == (100.0, date(2031, 5, 1))


def test_its_note_is_the_manager_s(auth_headers):
    bonus = _bonus()
    resp = _put(auth_headers, bonus, {'notes': 'راجعتها'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert db.session.get(EmployeeBonus, bonus.id).notes == 'راجعتها'


def test_a_bonus_added_by_hand_is_edited_by_hand(auth_headers):
    bonus = _bonus(with_rule=False)
    resp = _put(auth_headers, bonus, {'amount': 250.0})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert db.session.get(EmployeeBonus, bonus.id).amount == 250.0
