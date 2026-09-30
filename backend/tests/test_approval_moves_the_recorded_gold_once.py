"""Approving a held sale moves the gold its lines record -- once, not times the quantity (POSTGOLD-001).

A sale line's weight is the whole line's weight: the invoice's total_weight is
the sum of its lines' weights (336 of the 404 posted sales with a quantity
above one, 30 Sep 2026 copy; the other 68, all 7 Mar - 5 Apr 2026, stored one
piece). Posting at creation moves that weight. Posting later -- approval,
re-post (posting_routes._append_safe_transactions_for_invoice_gold) -- moves
weight x quantity: sale 1057 (18.7 g, one line of quantity 3) took 56.1 g out
of the display box; 2478 (66.9 g) took 518.8 g. Five sales stand 684.15 g over
on the copy, uncorrected.

xfail(strict) until the posting that comes later moves what the lines record.

Run:
    python -m pytest tests/test_approval_moves_the_recorded_gold_once.py -v
"""
import pytest

from app import app as flask_app
from models import SafeBoxTransaction, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.mark.xfail(strict=True, reason='POSTGOLD-001: the later posting multiplies by quantity')
def test_a_line_of_three_pieces_moves_its_weight_once(auth_headers, world):
    payload = _payload(world, 'sale_on_credit', held=True)          # held: a large discount
    payload['items'][0].update(weight=18.7, quantity=3)
    payload['total_weight'] = 18.7
    created = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=payload)
    assert created.status_code == 201 and created.get_json()['is_posted'] is False
    invoice_id = created.get_json()['id']

    approved = flask_app.test_client().post(f'/api/invoices/post/{invoice_id}', headers=auth_headers, json={})
    assert approved.status_code == 200, approved.get_data(as_text=True)[:200]
    db.session.expire_all()
    moved = sum((t.weight_21k or 0.0) * (1 if t.direction == 'in' else -1)
                for t in SafeBoxTransaction.query.filter(SafeBoxTransaction.invoice_id == invoice_id,
                                                         SafeBoxTransaction.ref_type != 'invoice_payment').all())
    assert round(moved, 4) == -18.7
