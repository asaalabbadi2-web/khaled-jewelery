"""Reading the payment methods writes nothing (PAYMENT-SYNC-1).

GET /payment-methods and /payment-methods/active «synced» the methods from a
legacy list in the settings (Settings.payment_methods) on every call: a method
it matched -- by id, by payment type inferred from a name, or by name -- had
its commission rate and fixed fee set to the list's. With the list null it
used one written in the code; and the column's own default was that list
(«بطاقة» 2.5 %, «تحويل» 1.5 %). On production the list is '[]', so nothing
moved (15 Oct 2026) -- but a new settings row, as the 2027 database starts
with (ADR-044), carries the default: measured, the first screen to list the
methods set the transfer's 0 % to 1.5 % (matched by «تحويل») and created two
methods, «بطاقة» at 2.5 % and «آجل», with no safe.

The methods are the owner's, set in their own screen; the list goes.
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import PaymentMethod, Settings, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _transfer():
    for pm in PaymentMethod.query.filter_by(payment_type='bank_transfer').all():
        pm.payment_type = f'old_{uuid.uuid4().hex[:6]}'     # the one transfer method, as on production
    pm = PaymentMethod(payment_type='bank_transfer', name='تحويل', commission_rate=0.0,
                       commission_fixed_amount=0.0, is_active=True)
    db.session.add(pm)
    db.session.flush()
    return pm


@pytest.mark.parametrize('path', ['/api/payment-methods', '/api/payment-methods/active'])
def test_listing_the_methods_changes_none_and_makes_none(auth_headers, path):
    row = Settings()            # a new settings row, with the column's default (as a new database)
    db.session.add(row)
    db.session.flush()
    pm = _transfer()
    before = PaymentMethod.query.count()
    g.pop('current_user', None)
    assert flask_app.test_client().get(path, headers=auth_headers).status_code == 200
    db.session.expire_all()
    assert db.session.get(PaymentMethod, pm.id).commission_rate == pytest.approx(0.0)
    assert PaymentMethod.query.count() == before


def test_the_settings_carry_no_payment_methods_list():
    assert not hasattr(Settings, 'payment_methods')
