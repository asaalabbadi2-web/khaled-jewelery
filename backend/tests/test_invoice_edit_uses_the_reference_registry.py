"""The edit asks the registry delete asks before it deletes anything (EDIT-003).

PUT /api/invoices/<id> deletes the invoice and re-creates it. Its cleanup is a
hand-written list, not services/invoice_retraction_guard.REFERENCES -- the
classification delete relies on, whose test fails when a table referencing an
invoice is left unclassified -- and it asks nothing about EVIDENCE, rows
another document wrote about the invoice. A return is one: Invoice.returns is
a plain backref, so deleting the original makes SQLAlchemy null the return's
original_invoice_id instead of refusing. The edit then succeeds and the return
no longer names its original. Delete refuses the same invoice with
has_financial_history.

(What the invoice OWNS is cleared: its gold obligations go by ORM cascade --
checked 30 Sep 2026, contrary to a first reading of the list.)

Fixed in UNPOST-001 U2: the edit asks financial_history_of before it deletes
anything, setting aside only the invoice's own draft payments
(draft_payments_of) -- 3170 was edited paid, and still can be.

Run:
    python -m pytest tests/test_invoice_edit_uses_the_reference_registry.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import Invoice, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_an_invoice_another_document_names_is_refused_like_delete_refuses_it(auth_headers):
    original = Invoice(invoice_type='بيع', invoice_type_id=99003, date=datetime(2026, 9, 29),
                       total=1.0, is_posted=False)
    db.session.add(original)
    db.session.flush()
    db.session.add(Invoice(invoice_type='مرتجع بيع', invoice_type_id=99004, date=datetime(2026, 9, 29),
                           total=1.0, is_posted=False, original_invoice_id=original.id))
    db.session.flush()
    resp = flask_app.test_client().put(f'/api/invoices/{original.id}', headers=auth_headers, json={'items': []})
    body = resp.get_json() or {}
    assert body.get('error') == 'has_financial_history', body
