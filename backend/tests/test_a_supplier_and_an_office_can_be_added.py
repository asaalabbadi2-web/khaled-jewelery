"""A new supplier, or a new closing office, can be added (production, 4 Oct 2026).

3f20338 (24 Sep 2026) dropped Supplier's cached balance columns -- the balance
is the ledger's -- but the two writers that create a supplier still passed them
(balance_cash, balance_gold_*k=0.0): adding a supplier, and adding an office
(its supplier is created with it), answered «حدث خطأ داخلي» -- TypeError,
'balance_cash' is an invalid keyword argument for Supplier. No test created
one through its route.

Run:
    python -m pytest tests/test_a_supplier_and_an_office_can_be_added.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Office, Supplier, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, monkeypatch):
    # The routes commit; under the fence a commit is a flush.
    monkeypatch.setattr(db.session, 'commit', db.session.flush)
    yield


def _post(path, headers, body):
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=headers, json=body)


def test_a_supplier_is_added(auth_headers):
    name = f'مورد {uuid.uuid4().hex[:6]}'
    resp = _post('/api/suppliers', auth_headers, {'name': name, 'phone': '0500000000', 'default_wage_type': 'cash',
                                                  'ensure_accounts': True})
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    assert Supplier.query.filter_by(name=name).count() == 1


def test_an_office_is_added_with_its_supplier(auth_headers):
    name = f'مكتب {uuid.uuid4().hex[:6]}'
    resp = _post('/api/offices', auth_headers, {'name': name, 'phone': '0500000001'})
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    office = Office.query.filter_by(name=name).one()
    assert office.supplier_id is not None
    assert db.session.get(Supplier, office.supplier_id).name == name


def test_no_writer_builds_a_supplier_with_a_field_it_does_not_have():
    """The class, not the two cases: every Supplier(...) the program builds
    names only what the model maps. Tools and devtools are scripts run by hand,
    not the program, and are not scanned."""
    import ast
    import pathlib
    from sqlalchemy import inspect as sa_inspect
    mapped = set(sa_inspect(Supplier).attrs.keys())
    root = pathlib.Path(__file__).resolve().parent.parent
    skip = ('venv', '_archived', 'alembic', 'tests', 'tools', 'devtools', 'migration_v2')
    bad = []
    for path in root.rglob('*.py'):
        rel = path.relative_to(root)
        if rel.parts[0] in skip or rel.name.startswith('test_'):
            continue
        try:
            tree = ast.parse(path.read_text(encoding='utf-8'))
        except (SyntaxError, UnicodeDecodeError):
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and (getattr(node.func, 'id', None) or getattr(node.func, 'attr', None)) == 'Supplier':
                bad += [f'{rel}:{node.lineno} {k.arg}' for k in node.keywords if k.arg and k.arg not in mapped]
    assert not bad, bad
