"""What a change of the race's points settings does, said before it is saved (bonus study م3د).

The owner (24 Oct 2026): «حيّ مع تحذير ومعاينة» -- the settings stay read
live: the open period is measured by them as they are when it is computed, so
a riyal-per-point doubled halfway through a month halves the whole month's
points, and the tiers of its pending bonus with them. Before saving, the page
says it in figures: each employee's points this month now and with the new
settings, and what each open points rule would pay now and then. Nothing is
written by the preview.

And the goals and bonuses read the race's points per invoice: they counted 1
whatever the race counted.

Run:
    python -m pytest tests/test_race_settings_preview.py -v
"""
import json
import uuid
from datetime import date, datetime, time

import pytest
from flask import g

from app import app as flask_app
from models import BonusRule, Employee, Invoice, InvoiceItem, Settings, db

TODAY = date.today()


def _settings(**cfg):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0, **cfg})
    db.session.flush()
    return settings


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    _settings()
    yield


def _employee():
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'P{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
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


def test_the_goals_and_bonuses_count_the_race_s_points_per_invoice():
    from services.performance_measures import measure
    _settings(points_source='invoice_count', points_per_invoice=2.0)
    emp = _employee()
    _sale(emp, 10)
    _sale(emp, 10)
    assert measure('points', emp.id, TODAY, TODAY) == pytest.approx(4.0)


def test_the_preview_says_this_month_s_points_and_pay_now_and_with_the_new_settings(auth_headers):
    emp = _employee()
    _sale(emp, 1200)
    rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers', bonus_value=0.0,
                     min_bonus=0.0, is_active=True, measure='points', period='monthly',
                     tiers=[{'from': 1000, 'per_unit': 2.5}], target_employee_ids=[emp.id])
    db.session.add(rule)
    db.session.flush()
    before = Settings.query.first().sales_race_settings

    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/sales-race/config/preview', headers=auth_headers,
                                        json={'cash_amount_per_point': 100.0})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    (row,) = [r for r in body['employees'] if r['employee_id'] == emp.id]
    assert (row['points_now'], row['points_new']) == (1200, 600)
    (paid,) = [r for r in body['rules'] if r['rule_id'] == rule.id and r['employee_id'] == emp.id]
    assert paid['amount_now'] == pytest.approx(3000.0)
    assert paid['amount_new'] == 0.0, '600 points are below the first tier'
    assert Settings.query.first().sales_race_settings == before, 'the preview writes nothing'


def test_the_preview_refuses_a_figure_it_cannot_read(auth_headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/sales-race/config/preview', headers=auth_headers,
                                        json={'cash_amount_per_point': 'خمسون'})
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invalid_race_settings'
