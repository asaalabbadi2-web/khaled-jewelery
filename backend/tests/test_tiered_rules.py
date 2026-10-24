"""A bonus rule is data: a measure, a period, tiers, a cap (bonus study م2).

The owner (24 Oct 2026): «ابدأ واعتمد توصياتك» -- tiers per point with a cap;
then, asked: «كل النقاط بسعر شريحتها» (1,600 points, tiers from 1,000 at 2.5
and from 1,500 at 3: all 1,600 at 3 = 4,800), and the live rule «الهدف
الشهري» moved to it as it is. A rule was its type's code: a measure, a
period and a payout fixed per type, «الحضور» and «الأداء» answering with
figures written in the code. Now a rule names its measure (the one measure,
ADR-058), its period, its tiers -- each from a threshold, per unit or a fixed
amount -- and its cap; and before it is saved the owner sees what it would
have paid in the months gone, beside what was paid.

Run:
    python -m pytest tests/test_tiered_rules.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import BonusRule, Employee, EmployeeBonus, Invoice, InvoiceItem, Settings, db

MAY = (date(2031, 5, 1), date(2031, 5, 31))


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0})
    db.session.flush()
    yield


def _employee():
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'T{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    db.session.add(emp)
    db.session.flush()
    return emp


def _sale(emp, when, *, points=None, total=10000.0):
    profit = (points or 0) * 50.0
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=when, total=total,
                  total_tax=0.0, is_posted=True, status='paid', employee_id=emp.id, profit_cash=profit,
                  total_weight=10.0)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=total, karat=21.0, weight=10.0))
    db.session.flush()
    return inv


def _rule(tiers, measure='points', period='monthly', **kw):
    rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers', bonus_value=0.0,
                     min_bonus=0.0, is_active=True, measure=measure, period=period, tiers=tiers, **kw)
    db.session.add(rule)
    db.session.flush()
    return rule


TIERS = [{'from': 1000, 'per_unit': 2.5}, {'from': 1500, 'per_unit': 3.0}]


def _pays(rule, emp, period=MAY):
    from bonus_calculator import BonusCalculator
    return BonusCalculator.estimate(emp, rule, *period)


# ── the tiers: all the measure at the tier it reached ───────────────────

@pytest.mark.parametrize('points,paid', [(1600, 4800.0), (1200, 3000.0), (999, 0.0)])
def test_all_the_points_are_paid_at_the_tier_they_reached(points, paid):
    emp = _employee()
    _sale(emp, datetime(2031, 5, 3, 10), points=points)
    assert _pays(_rule(TIERS), emp) == pytest.approx(paid)


def test_a_tier_may_pay_a_fixed_amount_and_the_cap_holds():
    emp = _employee()
    _sale(emp, datetime(2031, 5, 3, 10), points=1600)
    assert _pays(_rule([{'from': 1000, 'amount': 500.0}]), emp) == pytest.approx(500.0)
    assert _pays(_rule(TIERS, max_bonus=4000.0), emp) == pytest.approx(4000.0)


def test_another_measure_in_its_own_unit():
    emp = _employee()
    _sale(emp, datetime(2031, 5, 3, 10), total=20000.0)
    assert _pays(_rule([{'from': 10000, 'per_unit': 0.01}], measure='sales'), emp) == pytest.approx(200.0)


def test_the_rule_s_period_and_its_goal_s_threshold_are_its_own():
    from bonus_calculator import rule_period
    from services.goal_achievements import goal_target
    rule = _rule(TIERS, period='weekly')
    assert rule_period(rule) == 'weekly'
    emp = _employee()
    emp.goal_reward_type_weekly, emp.goal_bonus_rule_id_weekly = 'rule', rule.id
    db.session.flush()
    assert goal_target(emp, 'weekly', 'points') == pytest.approx(1000.0)


def test_the_calculation_says_its_measure_and_tier():
    from bonus_calculator import BonusCalculator
    emp = _employee()
    _sale(emp, datetime(2031, 5, 3, 10), points=1600)
    bonus = BonusCalculator.calculate_bonus(emp, _rule(TIERS), *MAY)
    data = bonus.calculation_data
    assert (data['measure'], data['value'], data['tier']['from']) == ('points', 1600, 1500)
    assert data['employee_points'] == 1600


# ── the API: what is saved is what is computed ───────────────────────────

def _post(path, headers, body):
    from flask import g
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=headers, json=body)


def test_a_tiered_rule_is_saved(auth_headers):
    resp = _post('/api/bonus-rules', auth_headers, {'name': 'شرائح', 'rule_type': 'tiered', 'measure': 'points',
                                                     'period': 'monthly', 'tiers': TIERS})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    rule = BonusRule.query.filter_by(name='شرائح').one()
    assert (rule.measure, rule.period, rule.tiers) == ('points', 'monthly', TIERS)


@pytest.mark.parametrize('tiers', [
    [], [{'from': 1500, 'per_unit': 3}, {'from': 1000, 'per_unit': 2}],
    [{'from': 1000, 'per_unit': 2, 'amount': 5}], [{'from': 1000}], [{'from': -1, 'per_unit': 2}],
    [{'from': 1000, 'per_unit': -2}]])
def test_tiers_that_say_nothing_or_contradict_are_refused(auth_headers, tiers):
    resp = _post('/api/bonus-rules', auth_headers, {'name': 'خطأ', 'rule_type': 'tiered', 'measure': 'points',
                                                     'period': 'monthly', 'tiers': tiers})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'invalid_tiers'


@pytest.mark.parametrize('field,value', [('measure', 'salary'), ('period', 'yearly')])
def test_an_unknown_measure_or_period_is_refused(auth_headers, field, value):
    body = {'name': 'خطأ', 'rule_type': 'tiered', 'measure': 'points', 'period': 'monthly', 'tiers': TIERS}
    body[field] = value
    resp = _post('/api/bonus-rules', auth_headers, body)
    assert resp.status_code == 400 and resp.get_json()['error'] == f'invalid_{field}'


@pytest.mark.parametrize('rule_type', ['attendance', 'performance', 'custom'])
def test_types_with_figures_written_in_the_code_are_gone(auth_headers, rule_type):
    resp = _post('/api/bonus-rules', auth_headers, {'name': 'لا', 'rule_type': rule_type, 'bonus_type': 'fixed',
                                                     'bonus_value': 100})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'rule_type_not_built'


# ── the preview: what it would have paid, beside what was paid ──────────

def test_the_preview_says_what_a_rule_would_have_paid_month_by_month(auth_headers):
    emp = _employee()
    _sale(emp, datetime(2031, 4, 10, 10), points=1200)
    _sale(emp, datetime(2031, 5, 10, 10), points=1600)
    db.session.add(EmployeeBonus(employee_id=emp.id, bonus_type='points_based', amount=3000.0, status='paid',
                                 period_start=date(2031, 4, 1), period_end=date(2031, 4, 30)))
    db.session.flush()
    before = EmployeeBonus.query.count()
    resp = _post('/api/bonus-rules/preview', auth_headers, {
        'rule': {'rule_type': 'tiered', 'measure': 'points', 'period': 'monthly', 'tiers': TIERS,
                 'target_employee_ids': [emp.id]},
        'until': '2031-05-31', 'periods': 2})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    rows = {(r['period_start'], r['employee_id']): r for r in body['rows']}
    assert rows[('2031-04-01', emp.id)]['amount'] == pytest.approx(3000.0)
    assert rows[('2031-04-01', emp.id)]['paid'] == pytest.approx(3000.0)
    assert rows[('2031-05-01', emp.id)]['amount'] == pytest.approx(4800.0)
    assert rows[('2031-05-01', emp.id)]['tier_from'] == 1500
    assert body['total'] == pytest.approx(7800.0)
    assert EmployeeBonus.query.count() == before, 'a preview writes nothing'
