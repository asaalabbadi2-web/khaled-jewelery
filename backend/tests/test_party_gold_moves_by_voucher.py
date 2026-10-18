"""A party's gold moves by a voucher naming the party, never a transfer (ADR-051 §5ب).

The owner (18 Oct 2026): «هل من الصحيح أن يتم التحويل بين ذهب لدى الأطراف
وخزائن المحل بسند؟» -- no. A party's gold safe sits on the party's own weight
account: what they hold of ours. A transfer is born approved and names no one;
AV-2026-00012 moved 185.4 g from an office to the scrap safe that way, and it
was a purchase paid in cash (corrected in stage 4, COR-2026-00035). So the
transfer and the melting refuse a party's safe at either end, by name; the
shop's own safes move as before.

Run:
    python -m pytest tests/test_party_gold_moves_by_voucher.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, SafeBox, Voucher, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _gold_safe(location, grams=0.0):
    acc = Account(account_number=f'72{uuid.uuid4().int % 10**7:07d}', name='حساب وزني', type='Liability',
                  transaction_type='gold', tracks_weight=True)
    db.session.add(acc)
    db.session.flush()
    safe = SafeBox(name=f'خزينة {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id, is_active=True,
                   stock_location=location)
    db.session.add(safe)
    db.session.flush()
    if grams:
        je = JournalEntry(entry_number=f'JE-PM-{uuid.uuid4().hex[:8]}', date=dt.datetime(2026, 10, 1),
                          description='ذهب', entry_type='عادي', is_posted=True, created_by='t')
        db.session.add(je)
        db.session.flush()
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=acc.id, description='ذهب',
                                        debit_21k=grams))
        db.session.flush()
    return safe


def _post(headers, path, body):
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api{path}', headers=headers, json=body)
    return resp.status_code, resp.get_json() or {}


def _transfer(headers, src, dst, grams=10.0):
    return _post(headers, '/safe-boxes/transfer-voucher', {
        'from_safe_box_id': src.id, 'to_safe_box_id': dst.id, 'weights': {'21k': grams}})


def _vouchers():
    return Voucher.query.count()


@pytest.mark.parametrize('party_end', ['from', 'to'])
def test_a_transfer_with_a_party_s_gold_is_refused_by_name(auth_headers, party_end):
    party = _gold_safe(None, 50.0)                 # an office holds 50 g of ours
    showroom = _gold_safe('showroom', 50.0)
    src, dst = (party, showroom) if party_end == 'from' else (showroom, party)
    before = _vouchers()

    status, body = _transfer(auth_headers, src, dst)

    assert status == 400, body
    assert body['error'] == 'party_gold_moves_by_voucher'
    assert body['safe_box_id'] == party.id
    assert party.name in body['message'] and 'سند' in body['message'], 'the screen shows why, in Arabic'
    assert _vouchers() == before, 'no voucher written'


def test_the_shop_s_own_safes_still_transfer(auth_headers):
    showroom = _gold_safe('showroom', 50.0)
    scrap = _gold_safe('scrap')

    status, body = _transfer(auth_headers, showroom, scrap)

    assert status == 201, body


def test_melting_from_a_party_s_gold_is_refused(auth_headers):
    party = _gold_safe(None, 50.0)
    scrap = _gold_safe('scrap')
    before = _vouchers()

    status, body = _post(auth_headers, '/melting-renewal', {
        'operation_type': 'melting', 'from_safe_box_id': party.id, 'to_safe_box_id': scrap.id,
        'lines': [{'karat': 21, 'gold_weight': 5.0}]})

    assert status == 400, body
    assert body['error'] == 'party_gold_moves_by_voucher'
    assert _vouchers() == before


def test_a_safe_says_its_group():
    party = _gold_safe(None)
    showroom = _gold_safe('showroom')
    assert party.to_dict()['group'] == 'party_gold'
    assert showroom.to_dict()['group'] == 'gold'


# Where a new gold safe's gold is, said when it is made. Nothing set
# stock_location but the migration of 13 Oct 2026, so every gold safe made
# since was a party's: out of the count, and refused by the transfer.

def _weight_account():
    acc = Account(account_number=f'71{uuid.uuid4().int % 10**7:07d}', name='حساب وزني', type='Asset',
                  transaction_type='gold', tracks_weight=True)
    db.session.add(acc)
    db.session.flush()
    return acc


def _create(headers, **extra):
    return _post(headers, '/safe-boxes', {
        'name': f'خزينة {uuid.uuid4().hex[:6]}', 'safe_type': 'gold', 'account_id': _weight_account().id, **extra})


def test_a_new_gold_safe_says_where_its_gold_is(auth_headers):
    status, body = _create(auth_headers)
    assert status == 400 and body['error'] == 'gold_safe_needs_its_place', body
    assert 'لدى طرف' in body['message']


@pytest.mark.parametrize('place, group', [('showroom', 'gold'), ('scrap', 'gold'), (None, 'party_gold')])
def test_the_place_given_is_kept(auth_headers, place, group):
    status, body = _create(auth_headers, stock_location=place)
    assert status == 201, body
    assert (body['stock_location'], body['group']) == (place, group)


def test_an_unknown_place_is_refused(auth_headers):
    status, body = _create(auth_headers, stock_location='basement')
    assert status == 400 and body['error'] == 'invalid_stock_location', body


def test_editing_a_safe_moves_its_place(auth_headers):
    safe = _gold_safe(None)
    g.pop('current_user', None)
    resp = flask_app.test_client().put(f'/api/safe-boxes/{safe.id}', headers=auth_headers,
                                       json={'stock_location': 'showroom'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert db.session.get(SafeBox, safe.id).stock_location == 'showroom'

    g.pop('current_user', None)
    resp = flask_app.test_client().put(f'/api/safe-boxes/{safe.id}', headers=auth_headers, json={'name': 'اسم'})
    assert resp.status_code == 200
    assert db.session.get(SafeBox, safe.id).stock_location == 'showroom', 'not sent: unchanged'
