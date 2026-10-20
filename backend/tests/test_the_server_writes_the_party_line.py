"""The server writes a customer's or supplier's line itself (the voucher screen review, cleanup release).

The voucher screen worked out the party's account -- its own, else its
category, else the aggregate -- and sent the balancing line; since release 1
the server refuses one off the party (test_a_voucher_party_line_is_on_the_party).
Now the screen sends what was paid or received and from where, and the party;
the server writes the party's side: one cash line for the cash, one gold line
per karat with its gross, net and stones -- the lines the screen sent, so a
voucher sent the old way and the new way is the same voucher.

A voucher that sends its party line still may (the old screens); employee and
«other» vouchers name their account themselves and are not written for.

Run:
    python -m pytest tests/test_the_server_writes_the_party_line.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Customer, Voucher, db
from tests.voucher_world import auto_post, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _post(headers, body):
    return flask_app.test_client().post('/api/vouchers', headers=headers, json=body)


def _lines(voucher_id):
    db.session.expire_all()
    v = db.session.get(Voucher, voucher_id)
    return sorted((ln.line_type, ln.account_id, ln.amount_type, round(ln.amount, 3), ln.karat,
                   round(ln.gross_weight or 0, 3), round(ln.stones_weight or 0, 3), ln.description)
                  for ln in v.account_lines.all())


def _payment(w, lines, *, with_party=None):
    return {'voucher_type': 'payment', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'supplier',
            'supplier_id': w['supplier'], 'account_lines': lines + (with_party or [])}


def test_a_cash_payment_without_its_party_line_is_the_voucher_it_was_with_it(auth_headers, vworld):
    auto_post(True)
    paid = [{'account_id': vworld['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': 500.0,
             'description': 'نقد'}]
    party = [{'account_id': vworld['supplier_acc'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 500.0,
              'description': 'نقد'}]
    old = _post(auth_headers, _payment(vworld, paid, with_party=party))
    new = _post(auth_headers, _payment(vworld, paid))
    assert (old.status_code, new.status_code) == (201, 201), new.get_data(as_text=True)[:300]
    assert _lines(new.get_json()['id']) == _lines(old.get_json()['id'])


def test_gold_by_karats_is_one_party_line_a_karat_with_its_weights(auth_headers, vworld):
    auto_post(True)
    paid = [
        {'account_id': vworld['gold'], 'line_type': 'credit', 'amount_type': 'gold', 'amount': 10.0, 'karat': 21,
         'gross_weight': 10.5, 'net_weight': 10.0, 'stones_weight': 0.5, 'description': 'ذهب'},
        {'account_id': vworld['gold'], 'line_type': 'credit', 'amount_type': 'gold', 'amount': 4.0, 'karat': 21,
         'gross_weight': 4.0, 'net_weight': 4.0, 'stones_weight': 0.0, 'description': 'ذهب'},
        {'account_id': vworld['gold'], 'line_type': 'credit', 'amount_type': 'gold', 'amount': 2.0, 'karat': 18,
         'description': 'ذهب'},
    ]
    resp = _post(auth_headers, _payment(vworld, paid))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    twin = Account.query.get(vworld['supplier_acc']).memo_account_id or vworld['supplier_acc']
    party = [ln for ln in _lines(resp.get_json()['id']) if ln[0] == 'debit']
    assert party == sorted([
        ('debit', twin, 'gold', 14.0, 21.0, 14.5, 0.5, 'ذهب عيار 21'),
        ('debit', twin, 'gold', 2.0, 18.0, 2.0, 0.0, 'ذهب عيار 18'),
    ])


def test_a_receipt_credits_the_customer(auth_headers, vworld):
    auto_post(True)
    body = {'voucher_type': 'receipt', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'customer',
            'customer_id': vworld['customer'], 'account_lines': [
                {'account_id': vworld['cash'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 750.0}]}
    resp = _post(auth_headers, body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert ('credit', vworld['customer_acc'], 'cash', 750.0, None, 0.0, 0.0, 'نقد') in _lines(resp.get_json()['id'])


def test_a_party_with_no_account_to_write_is_refused(auth_headers, vworld):
    auto_post(True)
    customer = Customer(name='بلا حساب', customer_code=f'C-NA-{vworld["cash"]}')
    db.session.add(customer)
    db.session.flush()
    body = {'voucher_type': 'receipt', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'customer',
            'customer_id': customer.id, 'account_lines': [
                {'account_id': vworld['cash'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 750.0}]}
    resp = _post(auth_headers, body)
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'party_has_no_account'


def test_an_other_party_is_not_written_for(auth_headers, vworld):
    auto_post(True)
    body = {'voucher_type': 'payment', 'date': datetime(2026, 10, 1).isoformat(), 'party_type': 'other',
            'account_lines': [
                {'account_id': vworld['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': 50.0}]}
    resp = _post(auth_headers, body)
    assert resp.status_code == 400, 'one side alone does not balance'
