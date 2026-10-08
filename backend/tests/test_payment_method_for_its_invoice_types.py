"""A payment method is taken only on the invoice types it is set for (PAY-TYPES-1).

Each payment method carries applicable_invoice_types, and the payment methods
screen sets it -- but nothing held an invoice to it: the scrap purchase screen
hid every method but cash and transfer by a rule written in its code, and the
server took any active method on any invoice. The owner (8 Oct 2026): it is a
setting. The server now refuses a method on an invoice type it is not set for
(an empty list is every type, as the lists' own filter reads it).

On the 6 Oct production copy all six methods list every type; scrap purchases
were paid in cash (761) and by transfer (22) only. alembic
20261008_payment_types_on_evidence makes the setting say so.

Run:
    python -m pytest tests/test_payment_method_for_its_invoice_types.py -v
"""
import importlib.util
import pathlib

import pytest

from app import app as flask_app
from models import PaymentMethod, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def _scrap_purchase(world):
    return _payload(world, 'scrap_purchase_paid', held=False)


def test_a_method_not_set_for_scrap_purchases_is_refused_on_one(auth_headers, world):
    pm = world['pm']
    pm.applicable_invoice_types = ['بيع']
    db.session.flush()

    resp = _post(auth_headers, _scrap_purchase(world))

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'payment_method_not_for_invoice_type'


def test_a_method_set_for_it_is_taken(auth_headers, world):
    pm = world['pm']
    pm.applicable_invoice_types = ['بيع', 'شراء من عميل']
    db.session.flush()

    resp = _post(auth_headers, _scrap_purchase(world))

    assert resp.status_code == 201, resp.get_json()


def test_a_method_set_for_no_type_in_particular_is_taken_on_any(auth_headers, world):
    pm = world['pm']
    pm.applicable_invoice_types = None
    db.session.flush()

    resp = _post(auth_headers, _scrap_purchase(world))

    assert resp.status_code == 201, resp.get_json()


# ── the release's correction (alembic 20261008_payment_types_on_evidence) ───

def _migration():
    path = (pathlib.Path(__file__).resolve().parent.parent / 'alembic' / 'versions'
            / '20261008_payment_types_on_evidence.py')
    spec = importlib.util.spec_from_file_location('payment_types_on_evidence', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_a_method_never_used_on_scrap_purchases_is_set_off_them(auth_headers, world):
    used = world['pm']
    used.applicable_invoice_types = ['بيع', 'شراء من عميل']
    never = PaymentMethod(payment_type='mada', name='مدى اختبار', commission_rate=0.0,
                          is_active=True, applicable_invoice_types=['بيع', 'شراء من عميل'])
    db.session.add(never)
    db.session.flush()
    assert _post(auth_headers, _scrap_purchase(world)).status_code == 201

    changed = _migration().correct_scrap_purchase_methods(db.session.connection())

    db.session.expire_all()
    assert 'شراء من عميل' in db.session.get(PaymentMethod, used.id).applicable_invoice_types
    assert 'شراء من عميل' not in db.session.get(PaymentMethod, never.id).applicable_invoice_types
    assert 'بيع' in db.session.get(PaymentMethod, never.id).applicable_invoice_types
    assert never.id in changed and used.id not in changed
