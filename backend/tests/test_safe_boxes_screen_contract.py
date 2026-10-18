"""What «إدارة الخزائن» reads from the server (SAFES-UI-1, the owner 12 Oct 2026).

The screen summed the balances itself and turned grams into the main karat
with a fixed 21, while the server held both answers; and it called the drawer,
the banks and the card networks one «إجمالي النقد». The server now says the
totals per type -- the amount for money, the grams in the main karat for gold
-- and the screen only shows them.

Who created a safe is the one signed in, not what the device sends: the
device sent 'admin' for everyone.

Run:
    python -m pytest tests/test_safe_boxes_screen_contract.py -v
"""
import pytest
from flask import g

from app import app as flask_app
from models import SafeBox, db
from tests.voucher_world import vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _balances(headers, **params):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/safe-boxes/balances', headers=headers, query_string=params)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_the_totals_per_type_are_the_servers_and_are_its_rows(auth_headers, vworld):
    db.session.add(SafeBox(name='خزينة الملخص', safe_type='cash', account_id=vworld['cash'], is_active=True))
    db.session.flush()
    body = _balances(auth_headers)

    totals = body['totals']
    assert body['main_karat'] > 0
    # Per group: the safe's type, but a party's gold apart from the shop's (ADR-051).
    for group in {r['group'] for r in body['rows']}:
        rows = [r for r in body['rows'] if r['group'] == group]
        t = totals[group]
        assert t['count'] == len(rows)
        assert t['cash'] == round(sum(r['balance']['cash'] for r in rows), 2)
        grams = sum((r['balance'].get('weight') or {}).get('total', 0.0) for r in rows)
        assert t['weight_main_karat'] == round(grams, 3), 'gold in the main karat, from the server'


def test_the_totals_follow_the_type_asked_for(auth_headers, vworld):
    db.session.add(SafeBox(name='خزينة نوع واحد', safe_type='cash', account_id=vworld['cash'], is_active=True))
    db.session.flush()
    body = _balances(auth_headers, type='cash')
    assert set(body['totals']) == {'cash'}


def test_who_created_a_safe_is_who_is_signed_in(auth_headers, vworld):
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/safe-boxes', headers=auth_headers, json={
        'name': 'خزينة المنشئ', 'safe_type': 'cash', 'account_id': vworld['cash'],
        'created_by': 'someone_else',
    })
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]
    box = db.session.get(SafeBox, resp.get_json()['id'])
    assert box.created_by == 'admin', 'not what the device says'


def test_the_stones_balance_has_one_route():
    rules = [r for r in flask_app.url_map.iter_rules() if r.rule == '/api/safe-boxes/stones-balance']
    assert len(rules) == 1, [r.endpoint for r in rules]
