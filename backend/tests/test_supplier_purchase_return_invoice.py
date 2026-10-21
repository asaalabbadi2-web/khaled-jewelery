"""A supplier purchase return: within its original, refused beyond it, allowed without one.

Brought in from the root (TEST-003): it posted against the seeded supplier 1
-- no accounts of its own -- in a test chart whose display stock (1300) had no
weight twin, so the purchase it returned was refused as unbalanced (the
supplier's 10 g with nothing against them). Unseen: the gate never ran it.
The same checks, in the world production has (as in
test_supplier_purchase_gold_follows_its_entry), behind the fence.

Run:
    python -m pytest tests/test_supplier_purchase_return_invoice.py -v
"""
from __future__ import annotations

import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (Account, InvoiceItem, InvoicePayment, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox,
                    Settings, Supplier, db)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


@pytest.fixture
def supplier():
    """As in production: the display stock (1300) keeps its weight on a memo
    account with its safe, and the supplier has its own accounts; invoices
    post at creation."""
    from party_account_service import ensure_supplier_accounts
    stock = Account.query.filter_by(account_number='1300').one()
    memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}', name=f'مخزون معروض وزني {_uid()}',
                   type='Asset', tracks_weight=True)
    db.session.add(memo)
    db.session.flush()
    stock.memo_account_id = memo.id
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add_all([SafeBox(name=f'المعروض {_uid()}', safe_type='gold', account_id=memo.id, is_active=True), s])
    db.session.flush()
    ensure_supplier_accounts(s)
    settings = Settings.query.first()
    settings.auto_post_invoices = True
    db.session.flush()
    return s


def _receivable_method() -> int:
    pm = PaymentMethod.query.filter_by(payment_type='receivable').first()
    if pm is None:
        pm = PaymentMethod(payment_type='receivable', name='آجل - اختبار', commission_rate=0.0, is_active=True)
        db.session.add(pm)
        db.session.flush()
    return int(pm.id)


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', json=payload, headers=headers)


def _purchase(headers, supplier, *, weight, quantity):
    resp = _post(headers, {
        'invoice_type': 'شراء', 'supplier_id': supplier.id, 'gold_type': 'new',
        'date': datetime.now().date().isoformat(), 'total': 0,
        'items': [{'name': 'قطعة اختبار شراء', 'karat': 21, 'weight': weight, 'quantity': quantity, 'price': 0}],
    })
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    invoice_id = int(resp.get_json()['id'])
    return invoice_id, int(InvoiceItem.query.filter_by(invoice_id=invoice_id).first().id)


def test_a_return_within_its_original_with_nothing_paid_creates_no_payment(auth_headers, supplier):
    original_id, original_item_id = _purchase(auth_headers, supplier, weight=10.0, quantity=2)
    resp = _post(auth_headers, {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': supplier.id, 'gold_type': 'new',
        'date': datetime.now().date().isoformat(), 'original_invoice_id': original_id,
        'payment_method_id': _receivable_method(), 'amount_paid': 0,
        'items': [{'name': 'قطعة اختبار مرتجع', 'karat': 21, 'weight': 10.0, 'quantity': 1, 'price': 0,
                   'original_invoice_item_id': original_item_id}],
    })
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    return_id = int(resp.get_json()['id'])
    je = JournalEntry.query.filter_by(reference_type='invoice', reference_id=return_id).first()
    assert je is not None
    assert InvoicePayment.query.filter_by(invoice_id=return_id).all() == []
    # The supplier's line is on the supplier's own accounts, not a cash fallback:
    # its weight on the weight twin (a return of grams at no price has no cash line).
    own = {int(supplier.account_id), int(Account.query.get(supplier.account_id).memo_account_id)}
    lines = JournalEntryLine.query.filter_by(journal_entry_id=je.id, supplier_id=supplier.id).all()
    assert lines, 'expected supplier-tagged lines'
    assert {int(ln.account_id) for ln in lines} <= own


def test_a_return_beyond_its_original_quantity_is_refused(auth_headers, supplier):
    original_id, original_item_id = _purchase(auth_headers, supplier, weight=5.0, quantity=1)
    resp = _post(auth_headers, {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': supplier.id, 'gold_type': 'new',
        'date': datetime.now().date().isoformat(), 'original_invoice_id': original_id,
        'items': [{'name': 'قطعة اختبار مرتجع 2', 'karat': 21, 'weight': 5.0, 'quantity': 2, 'price': 0,
                   'original_invoice_item_id': original_item_id}],
    })
    assert resp.status_code == 400
    assert (resp.get_json() or {}).get('error') in {
        'return_quantity_exceeds_original', 'return_weight_exceeds_original',
        'original_invoice_item_not_found', 'missing_original_invoice_item_id'}, resp.get_json()


def test_an_old_return_without_its_original_invoice_is_allowed(auth_headers, supplier):
    resp = _post(auth_headers, {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': supplier.id, 'gold_type': 'new',
        'date': datetime.now().date().isoformat(), 'total': 0, 'amount_paid': 0, 'items': [],
        'karat_lines': [{'karat': 21, 'weight_grams': 1.0, 'wage_per_gram': 0.0,
                         'description': 'legacy return without original invoice'}],
    })
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
