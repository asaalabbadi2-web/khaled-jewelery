"""A customer's gold at the main karat comes from the server, as a
supplier's does (the owner, 17 Nov 2026: the customers' and the suppliers'
lists in one table). The customers screen worked it out itself, with its own
formula; the suppliers' list has sent balance_gold_main since ADR-050 ر٠.
One conversion for both: services.party_live_balances.gold_in_main_karat.

Run:
    python -m pytest tests/test_customer_list_gold_main.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import Customer, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_the_customers_list_sends_the_gold_at_the_main_karat(auth_headers, monkeypatch):
    me = Customer(customer_code=f'C-{uuid.uuid4().hex[:6]}', name='عميل الذهب')
    db.session.add(me)
    db.session.flush()

    import services.party_live_balances as live
    real = live.compute_live_customer_balances

    def with_gold(customers):
        out = real(customers)
        out[int(me.id)] = {'cash': 0.0, '18k': 7.0, '21k': 10.0, '22k': 0.0, '24k': 0.0}
        return out

    monkeypatch.setattr(live, 'compute_live_customer_balances', with_gold)
    resp = flask_app.test_client().get('/api/customers', headers=auth_headers)
    assert resp.status_code == 200
    row = next(r for r in resp.get_json() if r['id'] == me.id)
    assert 'balance_gold_main' in row
    assert row['balance_gold_main'] == live.gold_in_main_karat(row)
