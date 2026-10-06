"""A clearing method settles in bulk only (the owner, 6 Oct 2026).

Tabby and Tamara deposit in batches -- Tamara settles everything before
Saturday on Saturday and deposits on Wednesday; Tabby the same on other days.
No method settles payment by payment, and the per-transaction path was broken
besides: POST /clearing/settlements/per-transaction called the settlement
without the payment it settled, the coverage guard refused every one, and it
answered 201 «settled_count: 0» (CLEARING-PTX-1). The mode is gone -- the
endpoint, the scheduler's path, the screen's button, the setting's option.
Old per-transaction vouchers (notes «per_tx:ip_<id>») are still read as
settled (tests/test_clearing_settlement_live_balance.py).

Run:
    python -m pytest tests/test_settlement_is_bulk_only.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import PaymentMethod, db


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


def _client():
    g.pop('current_user', None)
    return flask_app.test_client()


@pytest.fixture
def method():
    pm = PaymentMethod(payment_type='tamara', name=f'تمارا {uuid.uuid4().hex[:6]}', commission_rate=0.0,
                       settlement_mode='bulk', is_active=True)
    db.session.add(pm)
    db.session.flush()
    return pm


def test_there_is_no_per_transaction_settlement_endpoint(auth_headers):
    resp = _client().post('/api/clearing/settlements/per-transaction', headers=auth_headers, json={})
    assert resp.status_code in (404, 405), resp.status_code


def test_a_method_cannot_be_set_to_settle_per_transaction(auth_headers, method):
    resp = _client().put(f'/api/payment-methods/{method.id}', headers=auth_headers,
                         json={'settlement_mode': 'per_transaction'})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'settlement_mode_not_supported'
    assert db.session.get(PaymentMethod, method.id).settlement_mode == 'bulk'


def test_bulk_is_accepted(auth_headers, method):
    resp = _client().put(f'/api/payment-methods/{method.id}', headers=auth_headers,
                         json={'settlement_mode': 'bulk'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]


def test_the_scheduler_has_no_per_transaction_path():
    from clearing_settlement_scheduler import ClearingSettlementScheduler
    assert not hasattr(ClearingSettlementScheduler, '_settle_per_transaction')
