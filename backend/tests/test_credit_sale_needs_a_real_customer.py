"""A sale that leaves something owed needs a customer who can owe it (SALES-UX-2).

Measured on the 6 Oct production copy: 17 sales left part or all of their total
unpaid, every one on «عميل نقدي» #8 -- the walk-in customer, who is nobody. The
residue (BALANCE-001) sits on that account with no name to collect from. The
owner (7 Oct 2026): a credit sale needs a real customer. A sale paid in full
(cash, or cash and barter) does not.

Run:
    python -m pytest tests/test_credit_sale_needs_a_real_customer.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import Customer, Settings, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _customer(name):
    row = Customer(name=name, customer_code=f'T-{uuid.uuid4().hex[:8]}')
    db.session.add(row)
    db.session.flush()
    return row


def _sale(world, customer, *, paid):
    payload = _payload(world, 'sale_on_credit', held=False)
    payload['customer_id'] = customer.id
    payload['total_cost'] = 0.0
    if paid:
        payload['amount_paid'] = payload['total']
        payload['payments'] = [{'payment_method_id': world['pm'].id, 'amount': payload['total']}]
    return payload


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


@pytest.fixture(autouse=True)
def partial_payments_on(rollback_after_each):
    row = Settings.query.first() or Settings()
    row.allow_partial_invoice_payments = True
    db.session.add(row)
    db.session.flush()


def test_an_unpaid_sale_to_the_cash_customer_is_refused(auth_headers, world):
    resp = _post(auth_headers, _sale(world, _customer('عميل نقدي'), paid=False))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'credit_needs_customer'


def test_the_cash_customer_by_any_of_its_names(auth_headers, world):
    for name in ('نقدي', 'عميل كاش', '  عميل   نقدي '):
        resp = _post(auth_headers, _sale(world, _customer(name), paid=False))
        assert resp.get_json()['error'] == 'credit_needs_customer', name


def test_an_unpaid_sale_to_a_named_customer_is_taken(auth_headers, world):
    resp = _post(auth_headers, _sale(world, _customer('مؤسسة الأمل'), paid=False))
    assert resp.status_code == 201, resp.get_json()


def test_a_sale_paid_in_full_to_the_cash_customer_is_taken(auth_headers, world):
    resp = _post(auth_headers, _sale(world, _customer('عميل نقدي'), paid=True))
    assert resp.status_code == 201, resp.get_json()
