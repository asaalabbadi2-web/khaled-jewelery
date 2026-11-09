"""Gold paid out of a scrap holder leaves as scrap (the owner, 10 Nov 2026).

PV-2026-01534 (9 Nov 2026) paid a supplier 190.9 g of 21k from «ذهب الكسر
الرئيسي» by weight alone. The custody transfers had brought «كسر 21» in
(202.19 g), the payment took it out unclassified: «كسر 21» stayed as if held
and «بلا تصنيف» went to −81.431 g -- the night's STOCK_UNCLASSIFIED_NEGATIVE.
A scrap holder's gold has one category a karat, so the payment takes it, as
the transfer does (8 Nov): as much as the holder holds of it, the rest
unclassified as it was («أبني توصية سند الكسر»).

A cancelled voucher's reversal gives its categories back with its lines: a
cancelled transfer left the target «كسر 21» held and «بلا تصنيف» negative.

Worked gold paid out of the showroom still leaves by weight (STOCK-EXIT-1).

Run:
    python -m pytest tests/test_gold_payment_takes_scrap_category.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import Supplier, db
from tests.test_casting_and_assay import _held, _holds_scrap, _scrap_category
from tests.test_melting_and_renewal_go_one_way import _holds, _safe
from tests.test_transfer_is_not_melting import _transfer
from tests.voucher_world import auto_post


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    auto_post(True)
    yield


def _pay(headers, box, grams, karat=21):
    from party_account_service import ensure_supplier_accounts
    supplier = db.session.get(Supplier, 1)
    party = ensure_supplier_accounts(supplier).financial.id
    resp = flask_app.test_client().post('/api/vouchers', headers=headers, json={
        'voucher_type': 'payment', 'date': datetime(2026, 11, 9).isoformat(), 'party_type': 'supplier',
        'supplier_id': supplier.id, 'account_lines': [
            {'account_id': party, 'line_type': 'debit', 'amount_type': 'gold', 'amount': grams, 'karat': karat},
            {'account_id': box.account_id, 'line_type': 'credit', 'amount_type': 'gold', 'amount': grams,
             'karat': karat}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return resp.get_json()['id']


def _cancel(headers, voucher_id):
    resp = flask_app.test_client().post(f'/api/vouchers/{voucher_id}/cancel', headers=headers,
                                        json={'reason': 'test'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]


def test_gold_paid_out_of_the_scrap_takes_its_scrap_category(auth_headers):
    scrap = _safe('scrap')
    _holds_scrap(scrap, 21, 10.0)
    _pay(auth_headers, scrap, 10.0)
    assert _held(scrap) == {}, 'nothing left behind, nothing negative (PV-2026-01534)'


def test_what_the_scrap_holds_unclassified_leaves_unclassified(auth_headers):
    custody = _safe('custody')
    _holds_scrap(custody, 21, 4.0)
    _holds(custody, 21, 6.0)  # unclassified
    _pay(auth_headers, custody, 7.0)
    assert _held(custody) == {(21, None): 3.0}, '«كسر 21» given first, never below zero'


def test_worked_gold_still_leaves_by_weight(auth_headers):
    showroom = _safe('showroom')
    _holds(showroom, 21, 10.0)
    _pay(auth_headers, showroom, 4.0)
    assert _held(showroom) == {(21, None): 6.0}


def test_a_cancelled_payment_gives_its_scrap_category_back(auth_headers):
    scrap = _safe('scrap')
    _holds_scrap(scrap, 21, 10.0)
    _cancel(auth_headers, _pay(auth_headers, scrap, 10.0))
    assert _held(scrap) == {(21, _scrap_category(21).id): 10.0}


def test_a_cancelled_transfer_gives_its_scrap_category_back(auth_headers):
    custody, scrap = _safe('custody'), _safe('scrap')
    _holds_scrap(custody, 21, 10.0)
    resp = _transfer(auth_headers, custody, scrap, 10.0)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    _cancel(auth_headers, resp.get_json()['voucher']['id'] if 'voucher' in resp.get_json() else resp.get_json()['id'])
    category = _scrap_category(21).id
    assert _held(custody) == {(21, category): 10.0}
    assert _held(scrap) == {}, 'nothing negative left in the target'
