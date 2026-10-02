"""A barter sale and its scrap purchase are saved together, or neither is (BARTER-001, the owner 2 Oct 2026).

The owner's rule: a barter in a sale is a purchase and a sale -- the customer's
scrap is a «شراء من عميل» invoice linked to the sale (barter_sale_invoice_id),
and the sale is settled by its cash value (barter_total). The sale screen saved
the sale, then the purchase in a second request; when the second failed, the
sale stood settled by a barter whose gold the books never received.

The law: POST /api/invoices/barter-sale writes both in one transaction -- the
purchase linked to the sale -- or writes nothing.

Run:
    python -m pytest tests/test_barter_sale_is_one_transaction.py -v
"""
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import Invoice, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, monkeypatch):
    # The endpoint commits once at the end; under the fence a commit is a flush.
    monkeypatch.setattr(db.session, 'commit', db.session.flush)
    yield


def _payloads(w, *, scrap_value=250.0):
    """A 1,000 sale paid by cash and 1 g of 18k scrap below the live price (not held)."""
    cash = 1000.0 - scrap_value
    sale = {'customer_id': w['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': w['holder'].id, 'date': datetime.now().isoformat(),
            'total': 1000.0, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': cash,
            'barter_total': scrap_value,
            'payments': [{'payment_method_id': w['pm'].id, 'amount': cash}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]}
    purchase = {'customer_id': w['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
                'transaction_type': 'buy', 'employee_id': w['holder'].id,
                'scrap_holder_employee_id': w['holder'].id, 'date': datetime.now().isoformat(),
                'total': scrap_value, 'total_weight': 1.0, 'total_cost': scrap_value, 'total_tax': 0.0,
                'amount_paid': 0.0, 'payments': [], 'settlement_method': 'offset',
                'items': [{'name': 'كسر', 'karat': 18, 'weight': 1.0, 'standing_weight': 1.0,
                           'stones_weight': 0.0, 'price': scrap_value, 'net': scrap_value, 'quantity': 1}]}
    return sale, purchase


def _post(headers, body):
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/invoices/barter-sale', headers=headers, json=body)


def test_the_sale_and_its_purchase_are_saved_linked(auth_headers, world):
    sale, purchase = _payloads(world)
    resp = _post(auth_headers, {'sale': sale, 'purchase': purchase})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    body = resp.get_json()
    saved_purchase = db.session.get(Invoice, body['purchase']['id'])
    assert saved_purchase.barter_sale_invoice_id == body['sale']['id']
    assert float(db.session.get(Invoice, body['sale']['id']).barter_total) == 250.0


def test_a_purchase_that_fails_saves_no_sale(auth_headers, world):
    sale, purchase = _payloads(world)
    purchase['payments'] = [{'payment_method_id': 999999, 'amount': 1.0}]   # refused: no such method
    purchase['amount_paid'] = 1.0
    before = Invoice.query.count()
    resp = _post(auth_headers, {'sale': sale, 'purchase': purchase})
    assert resp.status_code >= 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'barter_not_saved'
    assert Invoice.query.count() == before, 'the sale was saved without its purchase'


def test_the_purchase_value_pays_the_sale_as_cash_does(auth_headers, world):
    """The owner (2 Oct 2026): in a barter the purchase invoice's value counts as
    a payment of the sale, as cash does -- 750 in cash and 250 of scrap pay a
    1,000 sale; the purchase is settled by the offset; only the cash moves a safe,
    and the customer's account nets to zero over the two invoices."""
    from models import SafeBoxTransaction
    from services.party_live_balances import compute_live_customer_balances
    before = compute_live_customer_balances([world['customer']])[world['customer'].id]['cash']
    sale, purchase = _payloads(world)
    body = _post(auth_headers, {'sale': sale, 'purchase': purchase}).get_json()
    db.session.expire_all()
    s, p = db.session.get(Invoice, body['sale']['id']), db.session.get(Invoice, body['purchase']['id'])
    assert (s.status, p.status) == ('paid', 'paid')
    cash_rows = SafeBoxTransaction.query.filter(SafeBoxTransaction.invoice_id.in_([s.id, p.id]),
                                                SafeBoxTransaction.amount_cash != 0).all()
    assert round(sum(t.amount_cash for t in cash_rows), 2) == 750.0, 'only the cash part moves a safe'
    after = compute_live_customer_balances([world['customer']])[world['customer'].id]['cash']
    assert round(after - before, 2) == 0.0, 'the customer owes nothing and is owed nothing'
