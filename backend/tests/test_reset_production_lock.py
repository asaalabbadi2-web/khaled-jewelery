"""RESET-1: on production no wipe runs -- a law, not a switch.

The «تصفير النظام» screen offers six wipe levels (balances, operations,
oversight, customers, factory data, the full wipe) and the route two more
(«all», «all_with_accounts»). Production refused them -- unless
ALLOW_DANGEROUS_RESETS=true, one line of .env away; and a request with no type
meant «all», a full re-initialisation. The owner, 14 Oct 2026: the lock holds
whatever the environment says (the switch opens the backup restore only), a
reset is tried on a restored copy, and no type is implied.

Every wipe function is replaced by one that fails the test, so a regression
that let a wipe through fails loudly -- the test database is never wiped, not
even when the witness runs on the parent.
"""
import pytest

from app import app as flask_app
from models import db

WIPES = ['balances_only', 'transactions', 'oversight_only', 'customers_suppliers', 'customers',
         'nuclear', 'factory_data', 'full_wipe', 'all', 'all_with_accounts']


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def production(monkeypatch):
    monkeypatch.setenv('YASAR_ENV', 'production')
    monkeypatch.setenv('ALLOW_DANGEROUS_RESETS', 'true')   # the switch that no longer opens a wipe
    import sys
    import routes.system as system

    def wiped(*args, **kwargs):
        raise AssertionError('a wipe ran on production')
    for name in dir(system):
        if name.startswith('_reset_'):
            monkeypatch.setattr(system, name, wiped)
    app_module = sys.modules[flask_app.import_name]
    for name in ('reset_database', 'reset_database_preserve_accounts'):
        if hasattr(app_module, name):
            monkeypatch.setattr(app_module, name, wiped)


@pytest.mark.parametrize('reset_type', WIPES)
def test_no_wipe_on_production_whatever_the_switch(app, auth_headers, production, reset_type):
    resp = flask_app.test_client().post('/api/system/reset', headers=auth_headers,
                                        json={'reset_type': reset_type, 'confirm': 'WIPE-ALL'})
    assert resp.status_code == 403, resp.get_data(as_text=True)[:200]
    assert resp.get_json()['error'] == 'production_lock'


def test_no_type_is_implied(app, auth_headers, production):
    resp = flask_app.test_client().post('/api/system/reset', headers=auth_headers, json={})
    assert resp.status_code == 400


def test_the_screen_is_told_the_lock_holds(app, auth_headers, production):
    resp = flask_app.test_client().get('/api/system/reset/info', headers=auth_headers)
    assert resp.status_code == 200
    assert resp.get_json()['data']['safety']['production_lock'] is True
