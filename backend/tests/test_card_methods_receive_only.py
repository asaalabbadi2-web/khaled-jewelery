"""A card's way to pay receives; it never pays out (17 Oct 2026).

A method whose safe is a clearing safe is set for «بيع» and «مرتجع بيع» only:
the clearing account is what the processor owes us, and nothing is paid from
it. The payment methods route refuses any other type for it, on creating and
on editing; alembic 20261018_card_methods_receive_only makes production's four
card methods say so (none was ever paid on a purchase).

Run:
    python -m pytest tests/test_card_methods_receive_only.py -v
"""
import importlib.util
import pathlib
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, PaymentMethod, SafeBox, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _safe(kind):
    acc = Account(account_number=f'15{uuid.uuid4().int % 10**6:06d}', name=f'خزينة {kind}', type='Asset')
    db.session.add(acc)
    db.session.flush()
    safe = SafeBox(name=f'{kind} {uuid.uuid4().hex[:6]}', safe_type=kind, account_id=acc.id, is_active=True)
    db.session.add(safe)
    db.session.flush()
    return safe


def _call(method, path, headers, body):
    g.pop('current_user', None)
    return getattr(flask_app.test_client(), method)(path, headers=headers, json=body)


def _create(headers, safe, types):
    return _call('post', '/api/payment-methods', headers, {
        'name': f'وسيلة {uuid.uuid4().hex[:6]}', 'payment_type': 'mada', 'commission_rate': 0.0,
        'default_safe_box_id': safe.id, 'applicable_invoice_types': types})


def test_a_card_method_set_to_pay_a_purchase_is_refused_by_name(auth_headers):
    resp = _create(auth_headers, _safe('clearing'), ['بيع', 'شراء', 'مرتجع شراء (مورد)'])
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'clearing_method_pays_out'
    assert body['invoice_types'] == ['شراء', 'مرتجع شراء (مورد)']


def test_a_card_method_for_sales_and_their_returns_is_taken(auth_headers):
    resp = _create(auth_headers, _safe('clearing'), ['بيع', 'مرتجع بيع'])
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]


def test_editing_a_card_method_onto_a_purchase_is_refused_and_changes_nothing(auth_headers):
    """Made through the route (the refusal rolls the session back: a method
    only flushed by the test would go with it)."""
    created = _create(auth_headers, _safe('clearing'), ['بيع'])
    assert created.status_code in (200, 201), created.get_data(as_text=True)[:300]
    method_id = (created.get_json().get('payment_method') or created.get_json())['id']

    resp = _call('put', f'/api/payment-methods/{method_id}', auth_headers,
                 {'applicable_invoice_types': ['بيع', 'شراء من عميل']})

    assert resp.status_code == 400 and resp.get_json()['error'] == 'clearing_method_pays_out'
    db.session.expire_all()
    assert db.session.get(PaymentMethod, method_id).applicable_invoice_types == ['بيع']


def test_cash_pays_purchases_as_before(auth_headers):
    resp = _create(auth_headers, _safe('cash'), ['بيع', 'شراء', 'شراء من عميل'])
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]


def _migration():
    path = (pathlib.Path(__file__).resolve().parent.parent / 'alembic' / 'versions'
            / '20261018_card_methods_receive_only.py')
    spec = importlib.util.spec_from_file_location('card_methods_receive_only', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_migration_leaves_a_card_method_its_sales_and_a_cash_method_alone():
    card = PaymentMethod(name=f'مدى {uuid.uuid4().hex[:6]}', payment_type='mada', is_active=True,
                         default_safe_box_id=_safe('clearing').id,
                         applicable_invoice_types=['بيع', 'مرتجع بيع', 'مرتجع شراء', 'شراء', 'مرتجع شراء (مورد)'])
    cash = PaymentMethod(name=f'نقد {uuid.uuid4().hex[:6]}', payment_type='cash', is_active=True,
                         default_safe_box_id=_safe('cash').id, applicable_invoice_types=['بيع', 'شراء'])
    db.session.add_all([card, cash])
    db.session.flush()

    changed = _migration().restrict_card_methods(db.session.connection())

    db.session.expire_all()
    assert db.session.get(PaymentMethod, card.id).applicable_invoice_types == ['بيع', 'مرتجع بيع']
    assert db.session.get(PaymentMethod, cash.id).applicable_invoice_types == ['بيع', 'شراء']
    assert card.id in changed and cash.id not in changed
