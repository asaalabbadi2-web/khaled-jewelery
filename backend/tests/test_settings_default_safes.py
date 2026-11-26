"""A default safe in the settings is a safe of its type, and active (the owner, 26 Nov 2026).

PUT and PATCH /settings took any number for the three default safes -- one
that is no safe, a gold safe as the main cash box, a cash box as the scrap
safe -- and posting then fell through them in silence: posting_routes skips a
safe that is not there, not of its type or not active, and takes the next in
its order. The law, in _apply_settings (shared by PUT and PATCH):
  - main_cash_safe_box_id is a cash safe; sale_gold_safe_box_id and
    main_scrap_gold_safe_box_id are gold safes;
  - a safe newly set is active -- one deactivated after it was set is not
    refused when sent again unchanged (an unchanged value is not a change);
  - none (null, '', 0) clears it, as before.
Refused: 400 invalid_default_safe, naming the setting.

Run:
    python -m pytest tests/test_settings_default_safes.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import Account, AppUser, SafeBox, Settings, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, vat_mapped):
    yield


@pytest.fixture
def admin():
    u = AppUser(username=f'admin-{uuid.uuid4().hex[:6]}', role='system_admin', is_active=True, password_hash='x')
    db.session.add(u)
    db.session.flush()
    return u


@pytest.fixture
def row():
    s = Settings.query.order_by(Settings.id).first()
    if s is None:
        s = Settings(main_karat=21)
        db.session.add(s)
        db.session.flush()
    return s


def _safe(safe_type, active=True):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name=f'حساب {uuid.uuid4().hex[:5]}', type='Asset',
                transaction_type='gold' if safe_type == 'gold' else 'cash', tracks_weight=safe_type == 'gold')
    db.session.add(a)
    db.session.flush()
    sb = SafeBox(name=f'خزينة {uuid.uuid4().hex[:5]}', safe_type=safe_type, account_id=a.id, is_active=active)
    db.session.add(sb)
    db.session.flush()
    return sb


def _put(user, body):
    g.pop('current_user', None)
    return flask_app.test_client().put('/api/settings', headers={'Authorization': f'Bearer {generate_token(user)}'},
                                       json=body)


def _patch(user, changes, reason='خزائن'):
    g.pop('current_user', None)
    client = flask_app.test_client()
    headers = {'Authorization': f'Bearer {generate_token(user)}'}
    seen = client.get('/api/settings/versions', headers=headers).get_json()['versions']
    return client.patch('/api/settings', headers=headers,
                        json={'changes': changes, 'versions': {k: seen.get(k, 0) for k in changes}, 'reason': reason})


@pytest.mark.parametrize('key, wrong', [
    ('main_cash_safe_box_id', 'gold'),
    ('sale_gold_safe_box_id', 'cash'),
    ('main_scrap_gold_safe_box_id', 'bank'),
])
def test_a_safe_of_another_type_is_refused(row, admin, key, wrong):
    before = getattr(row, key)
    for call in (lambda: _put(admin, {key: _safe(wrong).id}), lambda: _patch(admin, {key: _safe(wrong).id})):
        resp = call()
        assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
        assert resp.get_json()['error'] == 'invalid_default_safe'
        assert resp.get_json()['key'] == key
    db.session.expire_all()
    assert getattr(Settings.query.get(row.id), key) == before


def test_a_number_that_is_no_safe_is_refused(row, admin):
    resp = _patch(admin, {'main_cash_safe_box_id': 987654321})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'invalid_default_safe'
    resp = _put(admin, {'sale_gold_safe_box_id': 'abc'})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'invalid_default_safe'


def test_an_inactive_safe_is_not_newly_set(row, admin):
    resp = _patch(admin, {'main_scrap_gold_safe_box_id': _safe('gold', active=False).id})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'invalid_default_safe'


def test_a_safe_of_its_type_is_set_and_none_clears_it(row, admin):
    cash, gold = _safe('cash'), _safe('gold')
    resp = _patch(admin, {'main_cash_safe_box_id': cash.id, 'sale_gold_safe_box_id': gold.id})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    s = Settings.query.get(row.id)
    assert (s.main_cash_safe_box_id, s.sale_gold_safe_box_id) == (cash.id, gold.id)
    resp = _put(admin, {'sale_gold_safe_box_id': None})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    assert Settings.query.get(row.id).sale_gold_safe_box_id is None


def test_a_safe_deactivated_after_it_was_set_is_not_refused_when_sent_again(row, admin):
    gold = _safe('gold')
    row.main_scrap_gold_safe_box_id = gold.id
    gold.is_active = False
    db.session.flush()
    resp = _put(admin, {'main_scrap_gold_safe_box_id': gold.id, 'company_phone': '0544444444'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
