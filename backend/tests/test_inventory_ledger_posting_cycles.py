"""An invoice can be posted, reversed and posted again in the inventory ledger (ADR-002 addendum).

The ledger is append-only and allowed one row per (source line, movement):
one posting and one reversal per line, ever. A re-post after a reversal was
refused by uq_inventory_ledger_idempotency -- or, before that, silently skipped
because an original row existed -- so post, unpost, post left the invoice out
of inventory (UNPOST-001 U1, ADR-034). And 'purchase_from_customer_reversal'
did not fit movement_type's 30 characters: a customer purchase could never be
reversed. Now each re-post is the next cycle and its reversal carries the same
number; nothing is updated or deleted.

Run:
    python -m pytest tests/test_inventory_ledger_posting_cycles.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Invoice, InvoiceItem, InventoryLedger, db
from services.inventory_posting_service import InventoryPostingService


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _invoice(invoice_type, weight):
    inv = Invoice(invoice_type=invoice_type, invoice_type_id=uuid.uuid4().int % 900000 + 1,
                  date=datetime(2026, 10, 1), total=1.0, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سطر', karat=18.0, weight=weight, quantity=1, price=1.0))
    db.session.flush()
    db.session.refresh(inv)
    return inv


def _rows(inv):
    return (InventoryLedger.query.filter_by(source_type='invoice', source_id=inv.id)
            .order_by(InventoryLedger.id).all())


@pytest.mark.parametrize('invoice_type,sign', [('شراء من عميل', 1), ('بيع', -1)])
def test_post_reverse_post_reverse_post(invoice_type, sign):
    inv = _invoice(invoice_type, 0.5)
    for _ in range(2):
        assert len(InventoryPostingService.post(inv)) == 1
        assert len(InventoryPostingService.reverse(inv)) == 1
    assert len(InventoryPostingService.post(inv)) == 1

    rows = _rows(inv)
    assert [(r.movement_type.endswith('_reversal'), r.cycle) for r in rows] == [
        (False, 0), (True, 0), (False, 1), (True, 1), (False, 2)]
    assert round(sum(r.weight_delta for r in rows), 4) == round(sign * 0.5, 4)


def test_posting_twice_and_reversing_twice_write_nothing_more():
    inv = _invoice('شراء من عميل', 0.5)
    InventoryPostingService.post(inv)
    assert InventoryPostingService.post(inv) == []
    InventoryPostingService.reverse(inv)
    assert InventoryPostingService.reverse(inv) == []
    assert round(sum(r.weight_delta for r in _rows(inv)), 4) == 0.0
