"""The cash customer is one (the owner, 7 Oct 2026).

Measured on the 6 Oct production copy: 21 customers named «عميل نقدي», twenty
of them made from 4 to 8 March, when a sale without a customer created one
whenever the screen's list did not hold it. Since 9 March POST /customers
returns the existing cash customer instead of a new one (routes/customers.py)
-- but its witness, backend/test_cash_customer_dedupe.py, sat outside the
gate and had broken unseen (404 since the routes moved). This is that law,
in the gate. The sales screen picks the same row (SALES-UX-1): the name
exactly, the active first, the oldest.

Run:
    python -m pytest tests/test_cash_customer_is_one.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import Customer, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _customer(name, active=True):
    row = Customer(name=name, active=active,
                   customer_code=f'T-{uuid.uuid4().hex[:8]}')
    db.session.add(row)
    db.session.flush()
    return row


def _create(headers, name):
    return flask_app.test_client().post(
        '/api/customers', headers=headers,
        json={'name': name, 'ensure_accounts': False},
    )


def _cash_rows():
    db.session.expire_all()
    return Customer.query.filter(db.func.trim(Customer.name) == 'عميل نقدي').count()


def test_creating_the_cash_customer_returns_the_one_there(auth_headers):
    older = _customer('عميل نقدي')
    _customer('عميل نقدي')
    before = _cash_rows()

    resp = _create(auth_headers, 'عميل نقدي')

    assert resp.status_code in (200, 201), resp.get_json()
    assert resp.get_json()['id'] == older.id
    assert _cash_rows() == before


def test_the_name_is_read_with_its_spaces_folded(auth_headers):
    one = _customer('عميل نقدي')

    resp = _create(auth_headers, '  عميل   نقدي ')

    assert resp.get_json()['id'] == one.id


def test_an_active_one_is_preferred_to_an_older_inactive_one(auth_headers):
    _customer('عميل نقدي', active=False)
    active = _customer('عميل نقدي')
    # Any active «عميل نقدي» already in the books comes first; with none,
    # the one made here is.
    expected = (Customer.query.filter(db.func.trim(Customer.name) == 'عميل نقدي',
                                      Customer.active.is_(True))
                .order_by(Customer.id.asc()).first())

    resp = _create(auth_headers, 'عميل نقدي')

    assert resp.get_json()['id'] == expected.id
    assert expected.id <= active.id
