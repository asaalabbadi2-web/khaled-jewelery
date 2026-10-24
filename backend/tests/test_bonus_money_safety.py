"""A bonus is paid once, for its own period, and says who did what (bonus study, phase م0).

The owner (24 Oct 2026): «ابدأ واعتمد توصياتك» on
docs/plans/performance-race-and-bonuses-study.md. Phase م0 needs no decision:

  ث1  A rule owns its period. The scheduler ran every active rule on every
      run -- daily, weekly and monthly -- and the rule's «فترة النقاط» was
      saved and never read: the only rule on production, monthly, would have
      paid a week's 1,000 points again inside the month's.
  ث7  A pending bonus recomputed carries the snapshot of what computed it: its
      amount followed the rule, its snapshot stayed the first. An approved or
      paid one is never recomputed.
  ث8  Who rejected, paid or reversed is the signed-in user, never the body.
  ث10 A rule type the calculator has no branch for -- «مخصصة» -- is refused by
      name, not saved to pay nothing («الحضور» and «الأداء» stay refused by
      their flag, off on production; their removal is phase م2's).
  ث13 A failed bonus run is a nightly finding: 49 failed unseen for four months.

Run:
    python -m pytest tests/test_bonus_money_safety.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from bonus_calculator import BonusCalculator, rule_period
from models import BonusCalculationLog, BonusRule, Employee, EmployeeBonus, db

DAY = date(2031, 5, 14)
MONTH = (date(2031, 5, 1), date(2031, 5, 31))
WEEK = (date(2031, 5, 12), date(2031, 5, 18))


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _employee():
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'B{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    db.session.add(emp)
    db.session.flush()
    return emp


def _rule(period=None, value=100.0, **kw):
    conditions = {'points_period': period} if period else {}
    rule = BonusRule(name=f'قاعدة {uuid.uuid4().hex[:6]}', rule_type='fixed', bonus_type='fixed',
                     bonus_value=value, min_bonus=0.0, is_active=True, conditions=conditions, **kw)
    db.session.add(rule)
    db.session.flush()
    return rule


def _run(start, end, emp, rule, period_type=None):
    BonusCalculator.calculate_all_bonuses_for_period(start, end, employee_ids=[emp.id], rule_ids=[rule.id],
                                                     period_type=period_type)
    return EmployeeBonus.query.filter_by(employee_id=emp.id, bonus_rule_id=rule.id).all()


# ── ث1: a rule owns its period ───────────────────────────────────────────

def test_a_rule_s_period_is_its_points_period_and_monthly_without_one():
    assert rule_period(_rule('today')) == 'daily'
    assert rule_period(_rule('week')) == 'weekly'
    assert rule_period(_rule('month')) == 'monthly'
    assert rule_period(_rule()) == 'monthly'


def test_a_monthly_rule_is_not_paid_by_the_daily_or_the_weekly_run():
    emp, rule = _employee(), _rule('month')
    assert _run(DAY, DAY, emp, rule, 'daily') == []
    assert _run(*WEEK, emp, rule, 'weekly') == []
    assert len(_run(*MONTH, emp, rule, 'monthly')) == 1


def test_a_weekly_rule_is_paid_by_the_weekly_run_alone():
    emp, rule = _employee(), _rule('week')
    assert _run(*MONTH, emp, rule, 'monthly') == []
    assert len(_run(*WEEK, emp, rule, 'weekly')) == 1


def test_each_scheduled_run_names_its_period(monkeypatch):
    from bonus_scheduler import BonusScheduler
    seen = []

    def capture(*args, **kwargs):
        seen.append(kwargs.get('period_type'))
        return []
    monkeypatch.setattr(BonusCalculator, 'calculate_all_bonuses_for_period', staticmethod(capture))
    monkeypatch.setattr('bonus_scheduler._write_log', lambda *a, **k: None)
    scheduler = BonusScheduler(flask_app)
    scheduler.calculate_daily_bonuses()
    scheduler.calculate_weekly_bonuses()
    scheduler.calculate_monthly_bonuses()
    assert seen == ['daily', 'weekly', 'monthly']


# ── ث7: a pending bonus carries the snapshot of what computed it ──────────

def test_a_pending_bonus_recomputed_carries_its_new_snapshot_an_approved_one_is_left():
    emp, rule = _employee(), _rule('month', value=500.0)
    (pending,) = _run(*MONTH, emp, rule, 'monthly')
    rule.bonus_value = 999.0
    db.session.flush()
    (pending,) = _run(*MONTH, emp, rule, 'monthly')
    assert pending.amount == pytest.approx(999.0)
    assert pending.rule_snapshot['bonus_value'] == pytest.approx(999.0)
    assert pending.calculation_snapshot['result']['final_bonus'] == pytest.approx(999.0)

    pending.status = 'approved'
    db.session.flush()
    rule.bonus_value = 1.0
    db.session.flush()
    (approved,) = _run(*MONTH, emp, rule, 'monthly')
    assert (approved.amount, approved.rule_snapshot['bonus_value']) == (pytest.approx(999.0), pytest.approx(999.0))


# ── ث8: who did it is the session's ─────────────────────────────────────

def _post(path, headers, body):
    from flask import g
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=headers, json=body)


def test_who_rejected_and_who_paid_is_the_signed_in_user(auth_headers):
    emp, rule = _employee(), _rule('month')
    (bonus,) = _run(*MONTH, emp, rule, 'monthly')
    resp = _post(f'/api/bonuses/{bonus.id}/reject', auth_headers, {'reason': 'لا', 'rejected_by': 'مزيّف'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert db.session.get(EmployeeBonus, bonus.id).rejected_by == 'admin'

    # Who paid is witnessed on a real payment from a safe, in
    # test_bonus_voucher_is_born_posted (bonus study م4).


def test_a_bonus_is_not_marked_paid_with_the_payroll_and_no_entry(auth_headers):
    """«Add to payroll» marked a bonus paid with no entry -- the books went
    on owing it; it was never used and no screen offered it. Removed (the
    owner, 24 Oct 2026; bonus study م4)."""
    emp, rule = _employee(), _rule('month')
    bonus = EmployeeBonus(employee_id=emp.id, bonus_rule_id=rule.id, bonus_type='fixed', amount=10.0,
                          status='approved', period_start=date(2031, 6, 1), period_end=date(2031, 6, 30))
    db.session.add(bonus)
    db.session.flush()
    resp = _post(f'/api/bonuses/{bonus.id}/pay', auth_headers, {'payment_method': 'add_to_payroll'})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'payroll_payment_removed'
    db.session.refresh(bonus)
    assert (bonus.status, bonus.paid_at) == ('approved', None)


# ── ث10: what cannot be computed is not offered ─────────────────────────

def test_a_rule_type_the_calculator_cannot_compute_is_refused_by_name(auth_headers):
    resp = _post('/api/bonus-rules', auth_headers, {
        'name': 'لا تُحسب', 'rule_type': 'custom', 'bonus_type': 'fixed', 'bonus_value': 100})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'rule_type_not_built'
    assert BonusRule.query.filter_by(name='لا تُحسب').count() == 0
    rule = _rule('month')
    resp = flask_app.test_client().put(f'/api/bonus-rules/{rule.id}', headers=auth_headers, json={'rule_type': 'custom'})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert db.session.get(BonusRule, rule.id).rule_type == 'fixed'


# ── ث13: a failed run is a finding until a run of its period succeeds ───

def _log(period_type, status, when):
    db.session.add(BonusCalculationLog(period_type=period_type, period_start=when.date(), period_end=when.date(),
                                       status=status, run_at=when, message='boom' if status == 'failed' else ''))
    db.session.flush()


def test_a_failed_bonus_run_is_a_finding_until_its_period_runs_again():
    from services.books_invariants import BONUS_RUN_FAILED, CHECKS
    check = CHECKS[BONUS_RUN_FAILED]
    BonusCalculationLog.query.delete()
    _log('daily', 'success', datetime(2031, 5, 1, 1))
    _log('daily', 'failed', datetime(2031, 5, 2, 1))
    _log('daily', 'failed', datetime(2031, 5, 3, 1))
    _log('weekly', 'success', datetime(2031, 5, 3, 1))
    (fact,) = check()
    assert fact.subject_key == 'bonus_run:daily'
    assert fact.detail['failures'] == 2
    _log('daily', 'success', datetime(2031, 5, 4, 1))
    assert check() == []
