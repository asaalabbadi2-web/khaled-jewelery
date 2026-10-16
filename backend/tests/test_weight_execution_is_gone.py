"""The weight-closing execute screen and its profiles are gone (ADR-048 phase 3c).

The owner, 16 Oct 2026: «تنفيذ التسكير الوزني لسنا بحاجته الان». Its four
profiles (cleaning, melting, logistics, a valuation adjustment) never posted an
entry on production (0 «weight_profile» entries on the 16 Oct copy). A marked
expense closes its share of the waiting riyals from its own voucher, and the
price's grip on what waits is layer ⑤ -- read from the books, nothing to run.

Run:
    python -m pytest tests/test_weight_execution_is_gone.py -v
"""
import importlib.util

import pytest
from flask import g

from app import app as flask_app


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


def _client():
    g.pop('current_user', None)
    return flask_app.test_client()


def test_its_routes_answer_nothing(app, auth_headers):
    assert _client().post('/api/weight-closing/execute-profile', headers=auth_headers,
                          json={'profile_key': 'cleaning', 'cash_amount': 100.0}).status_code == 404
    assert _client().get('/api/weight-closing/profiles', headers=auth_headers).status_code == 404


def test_its_roles_are_retired_and_its_profiles_have_no_code():
    from accounting.role_registry import GROUPS, ROLES
    profile_roles = {k: r for k, r in ROLES.items() if k.startswith('weight_profile_')}
    assert set(profile_roles) == {'weight_profile_cleaning', 'weight_profile_melting',
                                  'weight_profile_logistics', 'weight_profile_valuation_diff'}
    assert all(r.retired for r in profile_roles.values())
    assert 'تنفيذ التسكير (اختياري)' not in GROUPS
    assert importlib.util.find_spec('services.weight_execution') is None


def test_its_settings_stay_for_the_office_reservations(app, auth_headers):
    """The reservation code's prefix and the cash account are read from them."""
    resp = _client().get('/api/weight-closing/settings', headers=auth_headers)
    assert resp.status_code == 200
    assert 'reservation_code_prefix' in resp.get_json()
