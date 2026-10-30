"""The manager's dashboard says what the banks and the instalment companies still owe us (DASH-5).

The owner, 30 Oct 2026, agreeing to all advised: a card payment waits in its
clearing safe until its deposit, and the dashboard did not say it. Each
clearing safe: its amount (the one computation the settlement uses), its
payments, its oldest one's day, and the deposit its method's schedule sets.

Run:
    python -m pytest tests/test_dashboard_says_what_the_banks_owe.py -v
"""
from datetime import date, datetime

import pytest

from tests.test_clearing_settlement_live_balance import (  # noqa: F401 (fixtures)
    app, rollback_after_each, mada, _sale_paid_by_mada,
)
from tests.retraction_world import world  # noqa: F401 (fixture)


def _clearing(app, headers):
    from flask import g
    g.pop('current_user', None)
    return app.test_client().get('/api/dashboard/admin/standing', headers=headers).get_json()['clearing']


def test_a_card_payment_waiting_for_its_deposit_is_said(app, auth_headers, mada):
    _sale_paid_by_mada(auth_headers, mada, 250.0)
    _sale_paid_by_mada(auth_headers, mada, 150.0)
    clearing = _clearing(app, auth_headers)
    (box,) = [s for s in clearing['safes'] if s['safe'] == mada['box'].name]
    assert (box['amount'], box['payments']) == (400.0, 2)
    assert box['oldest'] == date.today().isoformat()
    assert box['next_deposit'] is not None and box['next_deposit'] >= box['oldest']
    assert box['overdue'] is False
    assert clearing['total'] >= 400.0


def test_late_is_the_alarm_s_answer(app, auth_headers, mada, monkeypatch):
    """The 31 Oct copy: the card said Tamara late and Mada on time, the
    scheduler's alarm the opposite. Late is the alarm's answer, and its day."""
    import clearing_settlement_scheduler as scheduler
    from services.books_invariants import Fact
    _sale_paid_by_mada(auth_headers, mada, 250.0)
    monkeypatch.setattr(scheduler, 'overdue_settlements', lambda now, grace: [
        Fact(scheduler.OVERDUE_KIND, f"payment_method:{mada['pm'].id}", 250.0, {'due_day': '2026-10-31'})])
    (box,) = [s for s in _clearing(app, auth_headers)['safes'] if s['safe'] == mada['box'].name]
    assert (box['overdue'], box['overdue_since']) == (True, '2026-10-31')


def test_below_its_minimum_it_waits_and_is_not_late(app, auth_headers, mada):
    """Tamara's 2,392 waited below its 2,500 (the 31 Oct copy): no deposit is due
    for it -- the card says so, and not that it is late."""
    from models import db
    pm = mada['pm']
    pm.auto_settlement_enabled = True
    pm.settlement_mode = 'bulk'
    pm.settlement_schedule_type = pm.deposit_schedule_type = 'weekday'
    pm.settlement_weekday, pm.deposit_weekday = 4, 2
    pm.min_settlement_amount = 2500.0
    db.session.flush()
    _sale_paid_by_mada(auth_headers, mada, 400.0)
    (box,) = [s for s in _clearing(app, auth_headers)['safes'] if s['safe'] == mada['box'].name]
    assert box['payments'] == 1
    assert (box['below_minimum'], box['next_deposit'], box['overdue']) == (True, None, False)
