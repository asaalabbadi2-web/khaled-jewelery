"""Rejecting a held invoice (UNPOST-001 U2; RETRACT-001; ADR-034).

The owner's decisions of 1 Oct 2026: an unposted invoice's payment with no
voucher and no safe-box row is part of its draft, and rejecting withdraws it;
rejecting answers the approval alert and writes an audit row; the rejected
invoice's entries stay drafts -- it counts nowhere. Until then a held invoice
that had been paid (3170's shape) could be neither rejected nor deleted: its
payment "stood", and nothing could cancel a payment that had no voucher.

Run:
    python -m pytest tests/test_unpost_001_u2_reject.py -v
"""
import pytest

from app import app as flask_app
from models import AuditLog, InvoicePayment, JournalEntry, SafeBoxTransaction, SystemAlert, db
from tests.retraction_world import _create, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.mark.parametrize('shape', ('scrap_purchase_paid', 'scrap_purchase_unpaid', 'sale_on_credit'))
def test_a_held_invoice_is_rejected_and_counts_nowhere(auth_headers, world, shape):
    inv = _create(auth_headers, world, shape, held=True)
    resp = flask_app.test_client().post(f"/api/invoices/{inv['id']}/reject", headers=auth_headers,
                                        json={'reason': 'U2'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    i = inv['id']
    assert resp.get_json()['invoice']['status'] == 'rejected'
    assert InvoicePayment.query.filter_by(invoice_id=i).count() == 0
    assert all(je.is_draft and not je.is_posted
               for je in JournalEntry.query.filter_by(reference_type='invoice', reference_id=i).all())
    assert SafeBoxTransaction.query.filter_by(invoice_id=i).count() == 0
    assert SystemAlert.query.filter_by(entity_type='Invoice', entity_id=i, is_reviewed=False).count() == 0
    assert AuditLog.query.filter(AuditLog.entity_id == i, AuditLog.action == 'reject',
                                 AuditLog.success.is_(True)).count() == 1


def test_the_withdrawn_payment_is_named_in_the_audit_row(auth_headers, world):
    inv = _create(auth_headers, world, 'scrap_purchase_paid', held=True)
    flask_app.test_client().post(f"/api/invoices/{inv['id']}/reject", headers=auth_headers, json={})
    db.session.expire_all()
    row = AuditLog.query.filter_by(entity_id=inv['id'], action='reject').one()
    assert '"amount": 100000.0' in row.details
