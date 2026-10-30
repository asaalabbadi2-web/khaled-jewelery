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
