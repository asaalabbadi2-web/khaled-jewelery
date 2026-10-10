"""A document's entry is never touched alone -- at commit, on every session (UNPOST-001 U3).

The owner's rule (1 Oct 2026), held by journal_entry_guard below any route:
an invoice's entry is not deleted, soft-deleted or unposted without its
invoice, an invoice is not unposted leaving its entries posted, a voucher's
entry is not deleted while the voucher remains, and entries, invoices and
vouchers are not deleted -- nor their posted state updated -- in bulk. The
whole transaction is refused; nothing is repaired.

These go straight to the session, as a maintenance tool or the scheduler
would -- no route involved.

Run:
    python -m pytest tests/test_document_entry_guard.py -v
"""
import pytest

from app import app as flask_app
from journal_entry_guard import DocumentEntryTouchedAlone
from models import Invoice, JournalEntry, Voucher, db
from tests.retraction_world import _create, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _entry_of(invoice_id):
    return JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id).first()


def _refused_at_commit():
    with pytest.raises(DocumentEntryTouchedAlone):
        db.session.commit()
    db.session.rollback()


def test_unposting_an_invoice_entry_alone_is_refused(auth_headers, world):
    inv = _create(auth_headers, world, 'scrap_purchase_unpaid', held=False)
    je = _entry_of(inv['id'])
    je.is_posted = False
    _refused_at_commit()
    db.session.expire_all()
    assert _entry_of(inv['id']).is_posted is True


def test_unposting_an_invoice_and_leaving_its_entry_posted_is_refused(auth_headers, world):
    inv = _create(auth_headers, world, 'scrap_purchase_unpaid', held=False)
    Invoice.query.get(inv['id']).is_posted = False
    _refused_at_commit()


def test_soft_deleting_a_posted_invoice_entry_is_refused(auth_headers, world):
    inv = _create(auth_headers, world, 'sale_on_credit', held=False)
    je = _entry_of(inv['id'])
    je.is_posted = False          # past the database trigger (a separate statement) ...
    db.session.flush()
    je.is_deleted = True
    _refused_at_commit()          # ... and still refused: the invoice stands posted


def test_deleting_an_invoice_entry_while_the_invoice_remains_is_refused(auth_headers, world):
    inv = _create(auth_headers, world, 'scrap_purchase_unpaid', held=True)   # a draft entry
    db.session.delete(_entry_of(inv['id']))
    _refused_at_commit()


def test_deleting_a_voucher_entry_while_the_voucher_remains_is_refused(auth_headers, world):
    inv = _create(auth_headers, world, 'scrap_purchase_paid', held=False)
    voucher = Voucher.query.filter_by(reference_type='invoice', reference_id=inv['id']).first()
    je = JournalEntry.query.get(voucher.journal_entry_id)
    je.is_posted = False          # past the trigger, to reach the session guard
    db.session.flush()
    voucher.journal_entry_id = None
    db.session.delete(je)
    _refused_at_commit()


@pytest.mark.parametrize('model', [JournalEntry, Invoice, Voucher])
def test_a_bulk_delete_is_refused(model):
    with pytest.raises(DocumentEntryTouchedAlone):
        model.query.filter(model.id < 0).delete(synchronize_session=False)
    db.session.rollback()


@pytest.mark.parametrize('model', [JournalEntry, Invoice])
def test_a_bulk_update_of_the_posted_state_is_refused(model):
    with pytest.raises(DocumentEntryTouchedAlone):
        model.query.filter(model.id < 0).update({'is_posted': False}, synchronize_session=False)
    db.session.rollback()


def test_the_documents_own_operations_pass(auth_headers, world):
    """Post, unpost, re-post, reject, edit -- the sanctioned paths commit."""
    from tests.retraction_world import Settings
    row = Settings.query.first() or Settings()
    row.allow_unposting = True
    db.session.add(row)
    db.session.flush()
    client = flask_app.test_client()
    inv = _create(auth_headers, world, 'scrap_purchase_unpaid', held=False)
    assert client.post(f"/api/invoices/{inv['id']}/unpost", headers=auth_headers, json={}).status_code == 200
    assert client.post(f"/api/invoices/post/{inv['id']}", headers=auth_headers, json={}).status_code == 200
    held = _create(auth_headers, world, 'scrap_purchase_paid', held=True)
    assert client.post(f"/api/invoices/{held['id']}/reject", headers=auth_headers, json={}).status_code == 200


def test_an_invoice_whose_posted_entry_was_reversed_by_an_entry_may_be_written(auth_headers, world):
    """Stage 4 took back rejected 2821's and 3123's posted entries by reversing
    entries and left them posted (never edit a posted row). Writing to those
    invoices afterwards -- cancelling their closing orders (10 Oct 2026) -- was
    refused as a lone touch. A reversed entry no longer counts; one not
    reversed still does."""
    from datetime import datetime
    from journal_entry_guard import _check
    inv = _create(auth_headers, world, 'scrap_purchase_unpaid', held=False)
    je = _entry_of(inv['id'])
    db.session.get(Invoice, inv['id']).is_posted = False
    db.session.flush()
    with pytest.raises(DocumentEntryTouchedAlone):
        _check(db.session)

    db.session.add(JournalEntry(entry_number=f'REV-T-{je.id}', date=datetime.now(), description='عكس',
                                entry_type='عادي', is_posted=True, reference_type='journal_entry_reversal',
                                reference_id=je.id, created_by='t'))
    db.session.get(Invoice, inv['id']).weight_closing_status = 'cancelled'
    db.session.flush()
    _check(db.session)   # passes: the posted entry was taken back
