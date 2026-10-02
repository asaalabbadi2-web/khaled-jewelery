"""One permission catalog, and the roles the owner approved (2 Oct 2026, ADR-036).

Measured on the 2 Oct copy: 33 codes that routes ask for -- `voucher.approve`,
`invoice.post`, `invoice.edit`, `gold_advances.allocate`, `admin`, ... -- are
in no catalog, so no role holds them and only the system admin passes: the
manager could not approve a voucher, post or edit an invoice, or attribute a
voucher. And the app read only a user's own overrides, never the role's, so it
hid from the manager and the employees what the server allowed them.

The laws:
  - every code a route asks for is in the catalog;
  - every role holds only catalog codes, and holds exactly the owner's matrix
    (the grants are policy -- this pins the decision, changed only on purpose);
  - the app is sent the user's effective permissions: the role's, with the
    user's overrides on top;
  - a seller edits, rejects or deletes only the invoices that are theirs.

Run:
    python -m pytest tests/test_permission_catalog.py -v
"""
import ast
import uuid
from datetime import datetime
from pathlib import Path

import pytest

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, Employee, Invoice, db
from permissions import ALL_PERMISSIONS, ROLE_PERMISSIONS, ROLES

BACKEND = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'tests', 'venv', 'alembic', 'migrations', '_archived', 'graphify-out', 'backups',
             '__pycache__', 'instance', 'temp_pdfs'}

# The owner's matrix (ADR-036). M manager · C accountant · S storekeeper · E seller.
# The system admin holds everything.
MATRIX = {
    'users.view': '', 'users.create': '', 'users.edit': '', 'users.delete': '',
    'users.change_permissions': '', 'system.settings': '', 'system.backup': '', 'system.logs': '',
    'business.setup': 'C',
    'audit.view': 'MC',
    'employees.view': 'MC', 'employees.create': 'M', 'employees.edit': 'M', 'employees.delete': 'M',
    'employees.payroll': 'MC', 'employees.bonuses': 'M',
    'bonus.calculate': 'MC', 'bonus.approve': 'M', 'bonus.pay': 'MC',
    'bonus_rule.view': 'MC', 'bonus_rule.create': 'M', 'bonus_rule.update': 'M', 'bonus_rule.delete': 'M',
    'invoices.view': 'MCE', 'invoices.create': 'MCE', 'invoices.edit': 'MCE', 'invoices.delete': 'MC',
    'invoices.edit_others': 'MC', 'invoices.delete_others': 'MC', 'invoices.approve': 'M',
    'invoices.cancel': 'M', 'invoices.unpost': 'M', 'invoices.supplier': 'MC', 'invoices.view_others': 'MC',
    'customers.view': 'MCE', 'customers.create': 'MCE', 'customers.edit': 'MC', 'customers.delete': 'M',
    'suppliers.view': 'MCE', 'suppliers.create': 'MC', 'suppliers.edit': 'MC', 'suppliers.delete': 'M',
    'items.view': 'MCSE', 'items.create': 'MS', 'items.edit': 'MS', 'items.delete': 'M', 'items.adjust': 'M',
    'gold_price.view': 'MCSE', 'gold_price.update': 'M', 'costing.recompute': 'MC', 'costing.view': 'MC',
    'inventory.view': 'MCSE', 'inventory.count': 'MS', 'inventory.approve': 'M',
    'accounts.view': 'MC', 'accounts.create': 'C', 'accounts.edit': 'C', 'accounts.delete': '',
    'safe_boxes.view': 'MCSE', 'safe_boxes.create': 'M', 'safe_boxes.edit': 'M', 'safe_boxes.delete': 'M',
    'safe_boxes.transfer': 'MCS',
    'journal.view': 'MC', 'journal.create': 'MC', 'journal.edit': 'MC', 'journal.delete': '',
    'journal.post': 'MC', 'journal.unpost': 'M',
    'vouchers.view': 'MC', 'vouchers.create': 'MC', 'vouchers.edit': 'MC', 'vouchers.approve': 'M', 'vouchers.approve_within_limit': 'C',
    'vouchers.delete': 'M', 'vouchers.cancel': 'M', 'vouchers.attribute': 'MC',
    'supplier_settlement_adjustments.view': 'MC', 'supplier_settlement_adjustments.create': 'MC',
    'supplier_settlement_adjustments.approve': 'MC', 'supplier_settlement_adjustments.approve_other': 'M',
    'supplier_settlement_adjustments.post': 'MC', 'supplier_settlement_adjustments.reverse': 'MC',
    'supplier_settlement_adjustments.cancel': 'MC',
    'reports.financial': 'MC', 'reports.inventory': 'MCS', 'reports.sales': 'MC', 'reports.purchases': 'MC',
    'reports.customers': 'MC', 'reports.employees': 'M', 'reports.gold_position': 'MC',
    'print.invoices': 'MCE', 'print.reports': 'MCS', 'print.statements': 'MC',
}
LETTER = {'M': 'manager', 'C': 'accountant', 'S': 'storekeeper', 'E': 'employee'}


def _asked_codes():
    """Every code a route decorator asks for -- decorators only, not docstrings."""
    found = {}
    for path in BACKEND.rglob('*.py'):
        rel = path.relative_to(BACKEND)
        if set(rel.parts) & SKIP_DIRS or rel.name.startswith('test_'):
            continue
        try:
            tree = ast.parse(path.read_text(encoding='utf-8'))
        except (SyntaxError, UnicodeDecodeError):
            continue
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            for dec in node.decorator_list:
                if isinstance(dec, ast.Call) and getattr(dec.func, 'id', None) in (
                        'require_permission', 'require_any_permission'):
                    for arg in dec.args:
                        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                            found.setdefault(arg.value, []).append(f'{rel.as_posix()}::{node.name}')
    return found


def test_every_code_a_route_asks_for_is_in_the_catalog():
    phantom = {c: where for c, where in _asked_codes().items() if c not in ALL_PERMISSIONS}
    assert not phantom, 'codes no role can hold -- only the system admin passes: ' + '; '.join(
        f'{c} ({", ".join(sorted(set(w))[:3])})' for c, w in sorted(phantom.items()))


def _app_codes():
    """Every code the app asks for: hasPermission('x') and the home screen's route map."""
    import re
    lib = BACKEND.parent / 'frontend' / 'lib'
    found = {}
    for path in lib.rglob('*.dart'):
        if path.name.endswith('.backup.dart'):
            continue
        text = path.read_text(encoding='utf-8')
        for code in re.findall(r"hasPermission\('([a-z_]+\.[a-z_]+)'\)", text):
            found.setdefault(code, set()).add(path.name)
        block = re.search(r'_routePermissions\s*=\s*\{(.*?)\};', text, re.DOTALL)
        if block:
            for code in re.findall(r":\s*'([a-z_]+\.[a-z_]+)'", block.group(1)):
                found.setdefault(code, set()).add(path.name)
    return found


def test_every_code_the_app_asks_for_is_in_the_catalog():
    phantom = {c: w for c, w in _app_codes().items() if c not in ALL_PERMISSIONS}
    assert not phantom, 'the app asks for codes no role holds: ' + '; '.join(
        f'{c} ({", ".join(sorted(w))})' for c, w in sorted(phantom.items()))


def test_the_roles_are_the_owners():
    assert set(ROLES) == {'system_admin', 'manager', 'accountant', 'storekeeper', 'employee'}
    assert set(ROLE_PERMISSIONS['system_admin']) == set(ALL_PERMISSIONS)


def test_every_role_holds_exactly_the_owners_matrix():
    assert set(MATRIX) == set(ALL_PERMISSIONS), (
        'catalog and matrix differ: ' + str(sorted(set(MATRIX) ^ set(ALL_PERMISSIONS))))
    for letter, role in LETTER.items():
        expected = {code for code, roles in MATRIX.items() if letter in roles}
        held = set(ROLE_PERMISSIONS[role])
        assert held == expected, f'{role}: extra {sorted(held - expected)}, missing {sorted(expected - held)}'


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def fenced(app, db_fence):
    yield


def _user(role, *, employee_id=None, overrides=None):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x',
                   employee_id=employee_id, permissions=overrides)
    db.session.add(user)
    db.session.flush()
    return user


def test_the_app_is_sent_the_effective_permissions(fenced):
    manager = _user('manager', overrides={'bonus.calculate': True, 'customers.delete': False})
    sent = manager.to_dict()['effective_permissions']
    assert 'vouchers.approve' in sent and 'bonus.calculate' in sent
    assert 'customers.delete' not in sent, 'an override that takes a permission away'
    assert 'users.view' not in sent


def _seller():
    emp = Employee(employee_code=f'E-{uuid.uuid4().hex[:6]}', name='بائع', is_active=True)
    db.session.add(emp)
    db.session.flush()
    user = _user('employee', employee_id=emp.id)
    return emp, {'Authorization': f'Bearer {generate_token(user)}'}


def _unposted_sale(employee_id):
    inv = Invoice(invoice_type='بيع', invoice_type_id=900000 + uuid.uuid4().int % 99999, date=datetime.now(),
                  total=100.0, is_posted=False, employee_id=employee_id, status='unpaid')
    db.session.add(inv)
    db.session.flush()
    return inv.id


def test_a_seller_may_not_reject_another_sellers_invoice(fenced):
    _, headers = _seller()
    other = Employee(employee_code=f'E-{uuid.uuid4().hex[:6]}', name='آخر', is_active=True)
    db.session.add(other)
    db.session.flush()
    theirs = _unposted_sale(other.id)
    resp = flask_app.test_client().post(f'/api/invoices/{theirs}/reject', headers=headers, json={'reason': 'x'})
    assert resp.status_code == 403, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'not_your_invoice'


def test_a_seller_rejects_their_own_invoice(fenced):
    emp, headers = _seller()
    mine = _unposted_sale(emp.id)
    resp = flask_app.test_client().post(f'/api/invoices/{mine}/reject', headers=headers, json={'reason': 'x'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
