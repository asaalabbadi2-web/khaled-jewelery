"""A safe shows what waits for approval beside its posted balance (the owner, 2 Oct 2026).

The movement is written when the document posts (ADR-034) -- one truth for the
books. Since who creates does not approve (ADR-036 R4), a voucher may wait,
and a held invoice always did, while its money is already in the drawer. The
owner's choice: keep the movement at posting and SHOW what is pending, read
only -- posted + pending = what should be in hand. Nothing is written.

Pending is: a pending voucher's lines on a safe's account (debit in, credit
out, cash and gold), and a held invoice's cash payments on the safe they will
go to. A held invoice's gold is not counted yet (recorded).

Run:
    python -m pytest tests/test_safe_pending.py -v
"""
import pytest
from flask import g

from app import app as flask_app
from models import SafeBox, db
from tests.retraction_world import _create, world  # noqa: F401 (fixture)
from tests.voucher_world import auto_post, payload, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _row(headers, safe_box_id):
    g.pop('current_user', None)
    rows = flask_app.test_client().get('/api/safe-boxes/balances', headers=headers).get_json()['rows']
    return next(r for r in rows if r['id'] == safe_box_id)


def test_a_pending_voucher_shows_on_its_safe_until_approved(auth_headers, vworld):
    box = SafeBox(name='خزينة المعلّق', safe_type='cash', account_id=vworld['cash'], is_active=True)
    db.session.add(box)
    db.session.flush()
    auto_post(False)
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers,
                                        json=payload(vworld, 'cash_receipt', amount=750.0))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    before = _row(auth_headers, box.id)
    assert before['pending']['cash'] == 750.0 and before['pending']['documents'] == 1
    g.pop('current_user', None)
    assert flask_app.test_client().post(f"/api/vouchers/{resp.get_json()['id']}/approve",
                                        headers=auth_headers, json={}).status_code == 200
    after = _row(auth_headers, box.id)
    assert after['pending']['cash'] == 0.0
    assert round(after['balance']['cash'] - before['balance']['cash'], 2) == 750.0


def test_a_held_paid_purchase_shows_its_payment_out_until_posted(auth_headers, world):
    held = _create(auth_headers, world, 'scrap_purchase_paid', held=True)
    safe_id = world['pm'].default_safe_box_id
    assert _row(auth_headers, safe_id)['pending']['cash'] == -100000.0
    g.pop('current_user', None)
    assert flask_app.test_client().post(f"/api/invoices/post/{held['id']}", headers=auth_headers,
                                        json={}).status_code == 200
    assert _row(auth_headers, safe_id)['pending']['cash'] == 0.0
