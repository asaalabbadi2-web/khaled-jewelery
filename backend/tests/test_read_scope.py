"""What a seller reads (ADR-036 R3, the owner's recommendations of 2 Oct 2026).

(a) no cost or profit -- the server still holds a sale under cost for approval;
(b) the scrap purchase screen gets a suggested price, not the cost snapshot;
(c) the invoice list is the seller's own;
(d) the vouchers of their own invoice, and the employees' names only.
And the financial reads -- statements, balances -- are not the seller's.

Run:
    python -m pytest tests/test_read_scope.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, Employee, Invoice, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _employee(name):
    emp = Employee(employee_code=f'E-{uuid.uuid4().hex[:6]}', name=name, is_active=True)
    db.session.add(emp)
    db.session.flush()
    return emp


def _headers(role, employee=None):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x',
                   employee_id=employee.id if employee else None)
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _get(path, headers):
    g.pop('current_user', None)   # one app context for the module; each request in production has its own
    return flask_app.test_client().get(path, headers=headers)


def _sale(employee):
    inv = Invoice(invoice_type='بيع', invoice_type_id=700000 + uuid.uuid4().int % 99999, date=datetime.now(),
                  total=100.0, total_cost=60.0, is_posted=True, employee_id=employee.id, status='paid')
    db.session.add(inv)
    db.session.flush()
    return inv


def test_a_seller_lists_their_own_invoices(app):
    me, other = _employee('أنا'), _employee('غيري')
    mine, theirs = _sale(me), _sale(other)
    ids = {i['id'] for i in _get('/api/invoices?per_page=500', _headers('employee', me)).get_json()['invoices']}
    assert mine.id in ids and theirs.id not in ids
    ids = {i['id'] for i in _get('/api/invoices?per_page=500', _headers('manager')).get_json()['invoices']}
    assert {mine.id, theirs.id} <= ids


def test_a_seller_reads_an_invoice_without_its_cost(app):
    me = _employee('أنا')
    inv = _sale(me)
    body = _get(f'/api/invoices/{inv.id}', _headers('employee', me)).get_json()
    assert body['id'] == inv.id and not [k for k in body if 'cost' in k or 'profit' in k]
    assert 'total_cost' in _get(f'/api/invoices/{inv.id}', _headers('accountant')).get_json()


def test_the_cost_snapshot_is_not_the_sellers_but_a_suggested_price_is(app):
    seller = _headers('employee', _employee('أنا'))
    assert _get('/api/gold-costing', seller).status_code == 403
    resp = _get('/api/gold-costing/suggested-purchase-price', seller)
    assert resp.status_code == 200 and set(resp.get_json()) == {'price_per_gram_24k'}
    assert _get('/api/gold-costing', _headers('manager')).status_code == 200


def test_a_seller_reads_the_vouchers_of_their_own_invoice_only(app):
    me, other = _employee('أنا'), _employee('غيري')
    mine, theirs = _sale(me), _sale(other)
    seller = _headers('employee', me)
    assert _get(f'/api/vouchers?reference_type=invoice&reference_id={mine.id}', seller).status_code == 200
    assert _get(f'/api/vouchers?reference_type=invoice&reference_id={theirs.id}', seller).status_code == 403
    assert _get('/api/vouchers', seller).status_code == 403
    assert _get('/api/vouchers', _headers('accountant')).status_code == 200


def test_a_seller_sees_the_employees_names_only(app):
    _employee('اسم')
    rows = _get('/api/employees?per_page=500', _headers('employee', _employee('أنا'))).get_json()['employees']
    assert rows and all(set(r) == {'id', 'name'} for r in rows)


def test_the_bell_counts_for_those_who_approve(app):
    body = _get('/api/pending-actions', _headers('employee', _employee('أنا'))).get_json()
    assert body['total_pending_invoices'] == 0 and body['pending_invoices'] == []


@pytest.mark.parametrize('path', ['/api/accounts/balances', '/api/accounts', '/api/suppliers/1/ledger',
                                  '/api/customers/gold-balances', '/api/bonuses', '/api/vouchers/stats'])
def test_the_financial_reads_are_not_the_sellers(app, path):
    resp = _get(path, _headers('employee', _employee('أنا')))
    assert resp.status_code == 403, f'{path}: {resp.status_code}'
