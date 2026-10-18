"""A reservation's payment leaves a safe -- never an account named by a number (17 Oct 2026).

The payment voucher's cash account is the safe of the payment method chosen.
With no safe on the method the route fell back to the weight-closing setting
«cash_account_id», 1100 by default -- on production «النقدية», a parent group
with three children, not a box: the money would have left a heading. Never
taken on production (no reservation voucher there), refused now by name.

Run:
    python -m pytest tests/test_reservation_payment_needs_a_safe.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, OfficeReservation, PaymentMethod, Voucher, db
from tests.test_office_reservation_is_a_purchase import rworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_a_method_with_no_safe_is_refused_and_nothing_is_written(auth_headers, rworld):
    method = PaymentMethod(name=f'بلا خزينة {uuid.uuid4().hex[:6]}', payment_type='cash', is_active=True)
    db.session.add(method)
    db.session.flush()
    vouchers = Voucher.query.filter_by(reference_type='office_reservation').count()
    reservations = OfficeReservation.query.count()

    resp = flask_app.test_client().post('/api/office-reservations', headers=auth_headers, json={
        'office_id': rworld['office'].id, 'weight': 10, 'karat': 21, 'price_per_gram': 400.0,
        'execution_price_per_gram': 400.0, 'paid_amount': 500.0, 'payment_method_id': method.id})

    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'payment_method_has_no_safe'
    db.session.expire_all()
    assert Voucher.query.filter_by(reference_type='office_reservation').count() == vouchers
    assert OfficeReservation.query.count() == reservations


def test_the_setting_that_named_an_account_by_number_is_gone():
    from accounting.weight_closing import DEFAULT_WEIGHT_CLOSING_SETTINGS
    assert 'cash_account_id' not in DEFAULT_WEIGHT_CLOSING_SETTINGS
