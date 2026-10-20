"""A voucher's party line is on the party's own account (the voucher screen review, 20 Oct 2026).

The voucher screen worked out the party's account itself -- the customer's or
supplier's account, else its category, else the aggregate -- and sent the
balancing line; the server stored the party it was told and posted whatever
account came with it. A voucher could read «مفيد الحبيشي» and move another
supplier's balance. On the 17 Oct copy none had: of ~3,020 customer and
supplier vouchers, the 6 off their party's account are office reservation
deposits the server itself writes (to the 2200000 advances), never through
POST /vouchers.

The law: for a customer or supplier voucher, every line on the party's side
that is not a safe is on the party's account or its weight twin -- refused
with `party_line_not_on_party_account` otherwise, on create and on edit.
Employee and «other» vouchers name their account themselves and are not asked.

Run:
    python -m pytest tests/test_a_voucher_party_line_is_on_the_party.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import Supplier, Voucher, db
from party_account_service import ensure_supplier_accounts
from tests.voucher_world import _account, auto_post, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def parties(vworld):
    """The world's supplier on its account and that account's weight twin;
    and an account that is not the supplier's."""
    accounts = ensure_supplier_accounts(db.session.get(Supplier, vworld['supplier']))
    return {**vworld, 'own': accounts.financial.id, 'twin': accounts.memo.id,
            'stranger': _account('مورد آخر', 'Liability').id}


def _payment(w, party_account, *, gold=False, supplier_id=None):
    kind = {'amount_type': 'gold', 'amount': 10.0, 'karat': 21} if gold else {'amount_type': 'cash', 'amount': 500.0}
    return {'voucher_type': 'payment', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'supplier',
            'supplier_id': supplier_id or w['supplier'], 'account_lines': [
                {'account_id': party_account, 'line_type': 'debit', **kind},
                {'account_id': w['gold' if gold else 'cash'], 'line_type': 'credit', **kind}]}


def _post(headers, body):
    return flask_app.test_client().post('/api/vouchers', headers=headers, json=body)


def test_a_payment_on_another_suppliers_account_is_refused(auth_headers, parties):
    auto_post(True)
    before = Voucher.query.count()
    resp = _post(auth_headers, _payment(parties, parties['stranger']))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'party_line_not_on_party_account'
    assert Voucher.query.count() == before


def test_a_payment_on_the_suppliers_own_account_is_saved(auth_headers, parties):
    auto_post(True)
    assert _post(auth_headers, _payment(parties, parties['own'])).status_code == 201


@pytest.mark.parametrize('side', ['own', 'twin'])
def test_gold_on_the_supplier_is_saved_on_its_account_or_its_weight_twin(auth_headers, parties, side):
    auto_post(True)
    resp = _post(auth_headers, _payment(parties, parties[side], gold=True))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


def test_a_receipt_on_another_account_than_the_customers_is_refused(auth_headers, parties):
    auto_post(True)
    body = {'voucher_type': 'receipt', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'customer',
            'customer_id': parties['customer'], 'account_lines': [
                {'account_id': parties['cash'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 500.0},
                {'account_id': parties['stranger'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': 500.0}]}
    resp = _post(auth_headers, body)
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'party_line_not_on_party_account'


def test_an_edit_moving_the_party_line_off_the_party_is_refused(auth_headers, parties):
    auto_post(False)
    created = _post(auth_headers, _payment(parties, parties['own']))
    assert created.status_code == 201
    vid = created.get_json()['id']
    resp = flask_app.test_client().put(f'/api/vouchers/{vid}', headers=auth_headers,
                                       json=_payment(parties, parties['stranger']))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'party_line_not_on_party_account'


def test_an_other_party_names_its_account_itself(auth_headers, parties):
    auto_post(True)
    body = {**_payment(parties, parties['stranger']), 'party_type': 'other', 'supplier_id': None}
    assert _post(auth_headers, body).status_code == 201
