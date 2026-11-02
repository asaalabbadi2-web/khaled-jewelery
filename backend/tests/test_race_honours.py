"""The months an employee led the race, and the periods they reached their goal, kept (bonus study م3هـ).

The owner (24 Oct 2026): the race card shows, beside each employee, a crown
with the months they led and a target with the times they reached their goal.
«الأشهر دائمًا» -- the lead is a month's, by points; «فترات هدفه التي بلغها»
-- a closed period of the employee's own goal (daily, weekly or monthly) that
reached its target, by the one measure that pays it; «سجل محفوظ» -- each
recorded once when its period closes, so a later change of the race's settings
or of an invoice does not rewrite who led. The past is filled by the same
recording, period by period.

Run:
    python -m pytest tests/test_race_honours.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest

from models import BonusRule, Employee, Invoice, InvoiceItem, Settings, db

MAY = (date(2031, 5, 1), date(2031, 5, 31))
NOW = datetime(2031, 6, 1, 1, 0)


def _settings(cpp=50.0):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': cpp,
                                               'points_per_gram': 10.0})
    db.session.flush()


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    _settings()
    yield


def _employee(goal=None, goal_from=None):
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'H{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    if goal is not None:
        rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers',
                         bonus_value=0.0, min_bonus=0.0, is_active=True, measure='points', period='monthly',
                         tiers=[{'from': goal, 'per_unit': 2.5}], valid_from=goal_from)
        db.session.add(rule)
        db.session.flush()
        emp.goal_metric, emp.goal_monthly_enabled, emp.goal_points_monthly = 'points', True, float(goal)
        emp.goal_reward_type_monthly, emp.goal_bonus_rule_id_monthly = 'rule', rule.id
    db.session.add(emp)
    db.session.flush()
    return emp


def _sale(emp, day, points, month=5):
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8,
                  date=datetime(2031, month, day, 10), total=10000.0, total_tax=0.0, is_posted=True,
                  status='paid', employee_id=emp.id, profit_cash=points * 50.0, total_weight=10.0)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=10000.0, karat=21.0, weight=10.0))
    db.session.flush()


def _honours(emp):
    from services.race_honours import honours_of
    return honours_of([emp.id]).get(emp.id, {'crowns': 0, 'goals_reached': 0})


def test_the_month_s_leader_by_points_is_recorded_once():
    from services.race_honours import record_closed
    first, second = _employee(), _employee()
    _sale(first, 3, 900)
    _sale(second, 4, 400)
    record_closed(date(2031, 6, 1), NOW)
    record_closed(date(2031, 6, 1), NOW)
    assert _honours(first)['crowns'] == 1
    assert _honours(second)['crowns'] == 0


def test_a_tie_at_the_top_crowns_both():
    from services.race_honours import record_closed
    first, second = _employee(), _employee()
    _sale(first, 3, 700)
    _sale(second, 4, 700)
    record_closed(date(2031, 6, 1), NOW)
    assert (_honours(first)['crowns'], _honours(second)['crowns']) == (1, 1)


def test_a_goal_reached_in_a_closed_period_is_recorded_with_its_value_and_target():
    from models import RaceHonour
    from services.race_honours import record_closed
    reached, short = _employee(goal=1000), _employee(goal=1000)
    _sale(reached, 3, 1200)
    _sale(short, 4, 800)
    record_closed(date(2031, 6, 1), NOW)
    (row,) = RaceHonour.query.filter_by(employee_id=reached.id, kind='goal').all()
    assert (row.period, row.period_start, row.value, row.target) == ('monthly', MAY[0], 1200, 1000)
    assert _honours(short)['goals_reached'] == 0


def test_an_open_period_is_not_recorded():
    from services.race_honours import record_closed
    emp = _employee(goal=100)
    _sale(emp, 3, 900, month=6)
    record_closed(date(2031, 6, 20), NOW)
    assert _honours(emp) == {'crowns': 0, 'goals_reached': 0}


def test_what_is_kept_is_not_rewritten_by_a_later_change_of_the_settings():
    from services.race_honours import record_closed
    first, second = _employee(), _employee()
    _sale(first, 3, 900)
    _sale(second, 4, 400)
    record_closed(date(2031, 6, 1), NOW)
    _settings(cpp=1.0)
    record_closed(date(2031, 6, 1), NOW)
    assert (_honours(first)['crowns'], _honours(second)['crowns']) == (1, 0)


def test_the_past_is_filled_month_by_month():
    from services.race_honours import backfill
    emp = _employee(goal=500)
    _sale(emp, 3, 900, month=3)
    _sale(emp, 3, 900, month=4)
    _sale(emp, 3, 100, month=5)
    backfill(date(2031, 3, 1), date(2031, 6, 1), NOW)
    assert _honours(emp) == {'crowns': 3, 'goals_reached': 2}


def test_the_race_rows_carry_the_crowns_and_the_goals(auth_headers):
    from flask import g

    from app import app as flask_app
    from services.race_honours import record_closed
    emp = _employee(goal=500)
    _sale(emp, 3, 900)
    record_closed(date(2031, 6, 1), NOW)
    today = date.today()
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8,
                  date=datetime(today.year, today.month, today.day, 10), total=1000.0, total_tax=0.0,
                  is_posted=True, status='paid', employee_id=emp.id, profit_cash=500.0, total_weight=1.0)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='خاتم', quantity=1, price=1000.0, karat=21.0, weight=1.0))
    db.session.flush()
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/home/leaderboard?period=month&metric=points', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    rows = {r['id']: r for r in resp.get_json()['ranking']}
    assert (rows[emp.id]['crowns'], rows[emp.id]['goals_reached']) == (1, 1)
    assert all('crowns' in r and 'goals_reached' in r for r in rows.values())


def test_a_goal_is_no_goal_before_its_rule_s_validity():
    from services.race_honours import backfill
    emp = _employee(goal=500, goal_from=date(2031, 5, 1))
    _sale(emp, 3, 900, month=4)
    _sale(emp, 3, 900, month=5)
    backfill(date(2031, 4, 1), date(2031, 6, 1), NOW)
    assert _honours(emp)['goals_reached'] == 1, 'April is before the goal began'


# The owner, 3 Nov 2026: «يوسف ١٠ اشهر وعبدالله ١ شهر ... رغم اننا انهينا ١٠ اشهر».
# June 2026 on the 2 Nov copy: عبدالله 1,079.29 points, يوسف 1,078.596 -- each
# rounded to 1,079 before they were compared, so both were crowned: eleven
# crowns in ten months. Points are compared as they are; a tie is a true one.

def test_a_lead_by_less_than_a_point_is_a_lead_not_a_tie():
    from services.race_honours import record_closed
    first, second = _employee(), _employee()
    _sale(first, 3, 1079.29)
    _sale(second, 4, 1078.596)
    record_closed(date(2031, 6, 1), NOW)
    assert (_honours(first)['crowns'], _honours(second)['crowns']) == (1, 0)


def test_a_goal_short_by_less_than_a_point_is_not_reached():
    from services.race_honours import record_closed
    short = _employee(goal=1000)
    _sale(short, 3, 999.6)
    record_closed(date(2031, 6, 1), NOW)
    assert _honours(short)['goals_reached'] == 0


def test_a_month_crowned_twice_by_the_rounding_keeps_its_leader_alone():
    """The repair: a month kept with more than one crown is measured again as
    the points are; the crowns of those not at the top go, with an audit row.
    A month with one crown is its record, not measured again."""
    from models import AuditLog, RaceHonour
    from services.race_honours import _keep
    from services.repair.race_crowns_rounding import correct_rounded_ties
    first, second, alone = _employee(), _employee(), _employee()
    _sale(first, 3, 1079.29)
    _sale(second, 4, 1078.596)
    for emp in (first, second):                          # as the rounding kept them
        _keep(emp.id, 'leader', 'monthly', MAY[0], MAY[1], 1079, None, NOW)
    _keep(alone.id, 'leader', 'monthly', date(2031, 4, 1), date(2031, 4, 30), 5, None, NOW)

    plan = correct_rounded_ties(by='test', dry_run=True)
    assert [(r['month'], r['employee_id']) for r in plan['removed']] == [('2031-05', second.id)]
    assert _honours(second)['crowns'] == 1, 'a dry run writes nothing'

    correct_rounded_ties(by='test', dry_run=False)
    assert (_honours(first)['crowns'], _honours(second)['crowns'], _honours(alone)['crowns']) == (1, 0, 1)
    assert RaceHonour.query.filter_by(employee_id=first.id, kind='leader').one().value == pytest.approx(1079.29)
    assert AuditLog.query.filter_by(action='repair_race_crowns_rounding').count() >= 1
    assert correct_rounded_ties(by='test', dry_run=True)['removed'] == [], 'once is enough'
