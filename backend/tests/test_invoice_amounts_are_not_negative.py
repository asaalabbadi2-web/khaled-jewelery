"""A payment and a weight are never below nothing, on every invoice (ADR-062).

Measured on 27 Oct 2026 (a probe on the sale and the scrap purchase):
  - two payments of -200 and 1,200 on a 1,000 sale were saved paid, and 1,200
    went into the safe: the payment check added them (1,000, the total), and
    the posting skipped the negative line. A scrap purchase paid 150 for 100 so.
  - a line of -2 g was saved, its invoice weighing 0.001 g.
The screens' pay box takes no sign, so they did not reach it; the server is
held so now: a payment below nothing, or a weight below nothing, is refused --
before anything is saved. Nothing on the 27 Oct copy carries either.

Run:
    python -m pytest tests/test_invoice_amounts_are_not_negative.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Customer, Invoice, db
from tests.retraction_world import _payload, world  # noqa: F401 -- the fixture


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _named_customer():
    customer = Customer(customer_code=f'C-{uuid.uuid4().hex[:6]}', name='عميل مسمّى', phone='0500000001')
    db.session.add(customer)
    db.session.flush()
    return customer


def _sale(w, **extra):
    payload = _payload(w, 'sale_on_credit', held=False)
    payload['customer_id'] = _named_customer().id
    payload.update(extra)
    return payload


def _scrap(w, **extra):
    payload = _payload(w, 'scrap_purchase_paid', held=False)
    payload.update(extra)
    return payload


def _save(headers, payload):
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def _refused(resp, code):
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == code


def test_a_negative_payment_on_a_sale_is_refused(auth_headers, world):
    pm = world['pm'].id
    before = Invoice.query.count()
    _refused(_save(auth_headers, _sale(world, amount_paid=1000.0, payments=[
        {'payment_method_id': pm, 'amount': -200.0}, {'payment_method_id': pm, 'amount': 1200.0}])),
        'negative_payment')
    assert Invoice.query.count() == before, 'nothing saved'


def test_a_negative_payment_on_a_scrap_purchase_is_refused(auth_headers, world):
    pm = world['pm'].id
    _refused(_save(auth_headers, _scrap(world, payments=[
        {'payment_method_id': pm, 'amount': -50.0}, {'payment_method_id': pm, 'amount': 150.0}])),
        'negative_payment')


def test_an_empty_payment_line_is_still_passed_over(auth_headers, world):
    pm = world['pm'].id
    resp = _save(auth_headers, _scrap(world, payments=[
        {'payment_method_id': pm, 'amount': 0.0}, {'payment_method_id': pm, 'amount': 100.0}]))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


@pytest.mark.parametrize('field', ['weight', 'standing_weight', 'stones_weight'])
def test_a_negative_weight_on_a_scrap_purchase_is_refused(auth_headers, world, field):
    line = {'name': 'كسر', 'karat': 18, 'weight': 0.5, 'standing_weight': 0.5, 'stones_weight': 0.0,
            'price': 100.0, 'net': 100.0, 'quantity': 1, field: -0.5}
    _refused(_save(auth_headers, _scrap(world, items=[line])), 'negative_weight')


def test_a_negative_weight_on_a_sale_is_refused(auth_headers, world):
    line = {'name': 'سلسال', 'karat': 21, 'weight': -2.0, 'price': 1000.0, 'net': 1000.0,
            'quantity': 1, 'wage': 0, 'selling_price': 1000.0}
    _refused(_save(auth_headers, _sale(world, items=[line])), 'negative_weight')


def test_a_negative_karat_line_is_refused(auth_headers, world):
    _refused(_save(auth_headers, _sale(world, karat_lines=[{'karat': 21, 'weight_grams': -3.0}])),
             'negative_weight')


def test_a_sale_and_a_scrap_purchase_as_they_are_sent_are_taken(auth_headers, world):
    for payload in (_sale(world), _scrap(world)):
        resp = _save(auth_headers, payload)
        assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
