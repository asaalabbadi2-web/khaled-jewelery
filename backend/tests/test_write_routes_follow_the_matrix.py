"""The 42 write routes of SEC-007 ask for the owner's matrix (ADR-036, R2).

Before, any signed-in user could change the system settings, delete a customer,
a supplier or a payment method, set the gold price, reset the gold costing, and
create, edit or approve a manual voucher. Now each asks for its matrix code.
A refusal is decided by the decorator before the body runs, so an empty body is
enough to see it; an allowed role gets past it (whatever the body then says).

Run:
    python -m pytest tests/test_write_routes_follow_the_matrix.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, db

# (method, path, roles that pass) -- M manager, C accountant, S storekeeper, E seller
CASES = [
    ('PUT', '/api/settings', ''),
    ('POST', '/api/gold-costing/reset', ''),
    ('POST', '/api/gold-costing/recompute', 'MC'),
    ('POST', '/api/gold_price/update', 'M'),
    ('POST', '/api/payment-methods', 'C'),
    ('DELETE', '/api/customers/999999', 'M'),
    ('PUT', '/api/customers/999999', 'MC'),
    ('POST', '/api/customers', 'MCE'),
    ('POST', '/api/suppliers', 'MC'),
    ('DELETE', '/api/suppliers/999999', 'M'),
    ('POST', '/api/vouchers', 'MC'),
    ('POST', '/api/vouchers/999999/approve', 'M'),
]
ROLES = {'M': 'manager', 'C': 'accountant', 'S': 'storekeeper', 'E': 'employee'}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _headers(role):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _call(method, path, headers, body=None):
    # Every request here runs in the module's one app context, so `g` would keep
    # the previous request's user; in production each request has its own.
    g.pop('current_user', None)
    return flask_app.test_client().open(path, method=method, headers=headers, json=body or {})


@pytest.mark.parametrize('method,path,allowed', CASES, ids=[f'{m} {p}' for m, p, _ in CASES])
def test_each_role_meets_the_matrix(method, path, allowed):
    for letter, role in ROLES.items():
        resp = _call(method, path, _headers(role))
        refused = resp.status_code == 403 and (resp.get_json() or {}).get('error') == 'permission_denied'
        assert refused is (letter not in allowed), (
            f'{role} on {method} {path}: {resp.status_code} {resp.get_data(as_text=True)[:200]}')


@pytest.mark.parametrize('invoice_type', ['شراء', 'مرتجع شراء (مورد)'])
def test_a_seller_does_not_write_a_supplier_invoice(invoice_type):
    resp = _call('POST', '/api/invoices', _headers('employee'), {'invoice_type': invoice_type})
    assert resp.status_code == 403, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['required_permission'] == 'invoices.supplier'
    resp = _call('POST', '/api/invoices', _headers('accountant'), {'invoice_type': invoice_type})
    assert resp.status_code != 403, resp.get_data(as_text=True)[:300]
