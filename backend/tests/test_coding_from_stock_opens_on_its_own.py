"""Coding the stock on hand opens on its own day, apart from receiving (the owner, 19 Nov 2026).

«ماذا ان قمنا بترميز جميع القطع قبل موعد الجرد» -- then «سنبدأ بالبناجر ثم
الاطقم الى ان نصل لاخر تصنيف»: the pieces of the stock on hand coded before the
31 Dec count. Coding from stock opened only with receiving (Settings.receiving_from,
2027's first day), which also makes a supplier's new gold received first. Now
Settings.coding_from opens coding from stock alone, set to the server's day
when the manager turns it on; receiving keeps its own day.

Run:
    python -m pytest tests/test_coding_from_stock_opens_on_its_own.py -v
"""
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from models import Settings, db
from services.pieces import PieceRefused, open_coding
from services.receiving import coding_on, receiving_on

NOW = datetime(2026, 11, 19, 10, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    row = Settings.query.first()
    row.coding_from, row.receiving_from = None, None
    db.session.flush()
    yield


def _refusal(**kw):
    try:
        open_coding(**{'safe_box_id': -1, 'category_id': -1, 'weight': 10.0, 'by': 't',
                       'now': NOW, **kw})
    except PieceRefused as refused:
        return refused.code
    return None


def _put(headers, body):
    g.pop('current_user', None)
    return flask_app.test_client().put('/api/settings', headers=headers, json={**body, 'reason': 'ضبط الاختبار'})


def _get(headers):
    g.pop('current_user', None)
    return flask_app.test_client().get('/api/settings', headers=headers).get_json()


def test_closed_until_it_is_opened(app):
    assert coding_on(NOW) is False
    assert _refusal() == 'coding_not_open'


def test_the_manager_opens_it_on_the_servers_day_and_receiving_stays_off(app, auth_headers):
    resp = _put(auth_headers, {'coding_on': True})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    row = db.session.get(Settings, Settings.query.first().id)
    assert row.coding_from == date.today(), "the server's day, not the screen's"
    shown = _get(auth_headers)
    assert (shown['coding_active'], shown['coding_from']) == (True, date.today().isoformat())
    assert shown['receiving_active'] is False, 'receiving keeps its own day'
    assert receiving_on(datetime.now()) is False
    assert _refusal(now=datetime.now()) == 'coding_location_invalid', 'past the gate: refused for its safe only'


def test_opened_again_it_keeps_its_first_day_and_closed_it_is_shut(app, auth_headers):
    row = Settings.query.first()
    row.coding_from = date(2026, 11, 1)
    db.session.flush()
    assert _put(auth_headers, {'coding_on': True}).status_code == 200
    assert Settings.query.first().coding_from == date(2026, 11, 1)
    assert _put(auth_headers, {'coding_on': False}).status_code == 200
    assert Settings.query.first().coding_from is None
    assert _refusal(now=datetime.now()) == 'coding_not_open'


def test_receiving_opens_coding_too(app):
    row = Settings.query.first()
    row.receiving_from = date(2026, 11, 1)
    db.session.flush()
    assert coding_on(NOW) is True, "2027's receiving opens it as before"
