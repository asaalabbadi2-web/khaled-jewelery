"""Payment methods come in the order the owner set (PAY-ORDER-1).

PaymentMethod.display_order exists, PUT /payment-methods/update-order saves it,
and ApiService.updatePaymentMethodsOrder calls it -- but no screen did, and
GET /payment-methods and /payment-methods/active returned the rows unordered:
each invoice screen sorted them itself, or not. On the 6 Oct production copy
all six methods are 999, so the pay buttons came in no order (cash, used on
632 sales since June, could come after transfer, used on 7). The server now
returns them in their order, and the payment methods screen sets it.

Run:
    python -m pytest tests/test_payment_methods_in_their_order.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import PaymentMethod, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _method(name, order):
    pm = PaymentMethod(payment_type='cash', name=f'{name} {uuid.uuid4().hex[:5]}',
                       commission_rate=0.0, is_active=True, display_order=order)
    db.session.add(pm)
    db.session.flush()
    return pm


def _ids(headers, path):
    resp = flask_app.test_client().get(path, headers=headers)
    assert resp.status_code == 200, resp.get_json()
    return [m['id'] for m in resp.get_json()]


@pytest.mark.parametrize('path', ['/api/payment-methods', '/api/payment-methods/active'])
def test_methods_come_in_their_order(auth_headers, path):
    third = _method('ج', 3)
    first = _method('أ', 1)
    second = _method('ب', 2)

    ids = [i for i in _ids(auth_headers, path) if i in (first.id, second.id, third.id)]

    assert ids == [first.id, second.id, third.id]


def test_the_order_set_is_the_order_read(auth_headers):
    a, b, c = _method('أ', 1), _method('ب', 2), _method('ج', 3)

    resp = flask_app.test_client().put(
        '/api/payment-methods/update-order', headers=auth_headers,
        json={'methods': [{'id': c.id, 'display_order': 1},
                          {'id': a.id, 'display_order': 2},
                          {'id': b.id, 'display_order': 3}]})

    assert resp.status_code == 200, resp.get_json()
    ids = [i for i in _ids(auth_headers, '/api/payment-methods/active') if i in (a.id, b.id, c.id)]
    assert ids == [c.id, a.id, b.id]
