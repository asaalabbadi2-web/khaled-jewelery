"""A rule's validity is measured on the period it pays, by the days they share (bonus study م3ج).

A run computes the period gone -- yesterday, last week, last month -- and the
rule's validity was measured on the day of the run: a rule ending 30 Sep never
paid September, its run being on 1 Oct; and the preview of months gone read
today's validity for each. The owner (24 Oct 2026): «بالأيام المشتركة» -- the
validity is measured on the period itself, and only what fell inside it is
counted: a rule from 15 Sep pays on 15-30 Sep.

Run:
    python -m pytest tests/test_rule_validity.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from bonus_calculator import BonusCalculator
from models import BonusRule, Employee, Invoice, InvoiceItem, Settings, db

MAY = (date(2031, 5, 1), date(2031, 5, 31))
TIERS = [{'from': 1000, 'per_unit': 2.5}]


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0})
    db.session.flush()
    yield


def _employee():
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'V{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    db.session.add(emp)
    db.session.flush()
    return emp


def _sale(emp, day, points):
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8,
                  date=datetime(2031, 5, day, 10), total=10000.0, total_tax=0.0, is_posted=True, status='paid',
                  employee_id=emp.id, profit_cash=points * 50.0, total_weight=10.0)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=10000.0, karat=21.0, weight=10.0))
    db.session.flush()


def _rule(**validity):
    rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers', bonus_value=0.0,
                     min_bonus=0.0, is_active=True, measure='points', period='monthly', tiers=TIERS, **validity)
    db.session.add(rule)
    db.session.flush()
    return rule


def test_a_rule_valid_in_the_period_pays_it_whatever_the_day_of_the_run():
    emp = _employee()
    _sale(emp, 10, 1200)
    rule = _rule(valid_from=date(2031, 5, 1), valid_to=date(2031, 5, 31))
    assert BonusCalculator.estimate(emp, rule, *MAY) == pytest.approx(3000.0)


def test_a_rule_from_mid_period_counts_only_the_days_inside_it():
    emp = _employee()
    _sale(emp, 3, 700)
    _sale(emp, 20, 1200)
    rule = _rule(valid_from=date(2031, 5, 15))
    bonus = BonusCalculator.calculate_bonus(emp, rule, *MAY)
    assert bonus.amount == pytest.approx(1200 * 2.5), 'the 700 points of 3 May are before the rule'
    assert (bonus.period_start, bonus.period_end) == MAY, 'the bonus is still the period\'s'
    assert bonus.calculation_data['measured_from'] == '2031-05-15'


def test_a_rule_ended_before_the_period_pays_nothing_for_it():
    emp = _employee()
    _sale(emp, 10, 1200)
    rule = _rule(valid_to=date(2031, 4, 30))
    assert BonusCalculator.estimate(emp, rule, *MAY) == 0.0


def test_the_preview_reads_the_validity_on_each_period(auth_headers):
    emp = _employee()
    _sale(emp, 3, 700)
    _sale(emp, 20, 1200)
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/bonus-rules/preview', headers=auth_headers, json={
        'rule': {'measure': 'points', 'period': 'monthly', 'tiers': TIERS, 'target_employee_ids': [emp.id],
                 'valid_from': '2031-05-15'},
        'until': '2031-05-31', 'periods': 2})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    rows = {r['period_start']: r for r in resp.get_json()['rows']}
    assert rows['2031-05-01']['value'] == 1200
    assert rows['2031-04-01']['value'] == 0, 'April is before the rule'
