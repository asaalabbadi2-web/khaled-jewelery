"""The dashboard's liquidity: what could not be read is said so, never a quiet zero (the owner, 14 Nov 2026).

«بطاقة مركز السيوله ... مالها وما عليها؟»: the split of the cash safes and the
banks sat in a try whose except passed, so a failure read as 0.00 on the
card -- the shop told it holds nothing. Now a split not read is None, and
the card says «غير متاح».

Run:
    python -m pytest tests/test_dashboard_liquidity_not_read_is_not_zero.py -v
"""
import pytest
from flask import g

from app import app as flask_app


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _liquidity(headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/dashboard/admin', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()['liquidity']


def test_the_safes_read_give_the_cash_and_the_banks(auth_headers):
    liquidity = _liquidity(auth_headers)
    assert isinstance(liquidity['cash_in_hand'], (int, float))
    assert isinstance(liquidity['cash_in_banks'], (int, float))


def test_safes_not_read_are_not_zero(auth_headers, monkeypatch):
    import routes.admin_dashboard as dashboard

    def broken(*args, **kwargs):
        raise RuntimeError('the ledger is not there')
    monkeypatch.setattr(dashboard, 'safe_box_balances_bulk', broken)
    liquidity = _liquidity(auth_headers)
    assert liquidity['cash_in_hand'] is None and liquidity['cash_in_banks'] is None
