"""A voucher like one already saved is said before it is saved (VOUCHER-UX-1).

21 manual vouchers on the 6 Oct copy (305,210) were cancelled, four of them
as duplicates («تكرار», «مكرر», «مسجّل مرتين») -- found 4 hours to 206 days
later. The owner (9 Oct 2026): the same party, the same voucher type, the
same cash amount or the same gold weight, within 30 days of each other, is
said in the review before saving -- a warning, not a refusal.

POST /api/vouchers/similar takes the body a voucher is created with and
answers with the vouchers that look like it; it writes nothing.

Run:
    python -m pytest tests/test_similar_vouchers.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import Voucher, db
from tests.voucher_world import auto_post, payload, vworld  # noqa: F401 (fixture)

# An amount no other test pays, so the shared test database cannot answer.
AMOUNT = 4321.17


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _create(headers, body):
    resp = flask_app.test_client().post('/api/vouchers', headers=headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return resp.get_json()['id']


def _similar(headers, body):
    resp = flask_app.test_client().post('/api/vouchers/similar', headers=headers, json=body)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return [row['id'] for row in resp.get_json()['similar']]


def _on(body, day):
    return {**body, 'date': datetime(2026, 10, day).isoformat()}


def test_the_same_payment_to_the_same_supplier_is_said(auth_headers, vworld):
    auto_post(True)
    saved = _create(auth_headers, payload(vworld, 'cash_payment', AMOUNT))

    assert _similar(auth_headers, payload(vworld, 'cash_payment', AMOUNT)) == [saved]


def test_its_number_date_and_amounts_are_given(auth_headers, vworld):
    auto_post(True)
    _create(auth_headers, payload(vworld, 'cash_payment', AMOUNT))

    resp = flask_app.test_client().post(
        '/api/vouchers/similar', headers=auth_headers,
        json=payload(vworld, 'cash_payment', AMOUNT))
    row = resp.get_json()['similar'][0]

    assert row['voucher_number']
    assert row['date'].startswith('2026-10-01')
    assert round(row['amount_cash'], 2) == AMOUNT


def test_the_same_gold_weight_is_said(auth_headers, vworld):
    auto_post(True)
    saved = _create(auth_headers, payload(vworld, 'gold_payment', AMOUNT))

    assert _similar(auth_headers, payload(vworld, 'gold_payment', AMOUNT)) == [saved]


def test_another_amount_is_not(auth_headers, vworld):
    auto_post(True)
    _create(auth_headers, payload(vworld, 'cash_payment', AMOUNT))

    assert _similar(auth_headers, payload(vworld, 'cash_payment', AMOUNT + 1)) == []


def test_another_type_is_not(auth_headers, vworld):
    auto_post(True)
    _create(auth_headers, payload(vworld, 'cash_payment', AMOUNT))
    receipt = payload(vworld, 'cash_receipt', AMOUNT)

    assert _similar(auth_headers, receipt) == []


def test_within_thirty_days_either_side_and_not_beyond(auth_headers, vworld):
    auto_post(True)
    _create(auth_headers, _on(payload(vworld, 'cash_payment', AMOUNT), 1))

    later = {**payload(vworld, 'cash_payment', AMOUNT), 'date': datetime(2026, 10, 31).isoformat()}
    beyond = {**payload(vworld, 'cash_payment', AMOUNT), 'date': datetime(2026, 11, 1).isoformat()}
    assert len(_similar(auth_headers, later)) == 1
    assert _similar(auth_headers, beyond) == []


def test_a_cancelled_voucher_is_not(auth_headers, vworld):
    auto_post(True)
    saved = _create(auth_headers, payload(vworld, 'cash_payment', AMOUNT))
    db.session.get(Voucher, saved).status = 'cancelled'
    db.session.flush()

    assert _similar(auth_headers, payload(vworld, 'cash_payment', AMOUNT)) == []


def test_the_voucher_being_edited_is_not_its_own_duplicate(auth_headers, vworld):
    auto_post(True)
    saved = _create(auth_headers, payload(vworld, 'cash_payment', AMOUNT))
    body = {**payload(vworld, 'cash_payment', AMOUNT), 'exclude_id': saved}

    assert _similar(auth_headers, body) == []


def test_asking_writes_nothing(auth_headers, vworld):
    auto_post(True)
    before = Voucher.query.count()

    _similar(auth_headers, payload(vworld, 'cash_payment', AMOUNT))

    assert Voucher.query.count() == before
