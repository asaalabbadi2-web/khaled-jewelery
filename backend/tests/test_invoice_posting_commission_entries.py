"""Posting an invoice records its karat-difference and 24k-settlement commission entries.

post_invoice builds these two entries through lazily imported helpers. Since
the July 2026 routes migration (0232533) it imported them from `routes`, where
they no longer live: the ImportError was caught and printed, and the invoice
posted WITHOUT the entry. Neither helper had run for a real invoice before July,
so none ever has -- invoice 3020 (purchase #178, posted 15 Sep 2026) carries a
307.37 karat-difference commission that was never recorded.

These tests post through the real route and check each entry's amount,
accounts and sides -- not merely that one exists -- because fixing the import
puts this accounting on real invoices for the first time.

Run:
    python -m pytest tests/test_invoice_posting_commission_entries.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, JournalEntry, JournalEntryLine, SafeBoxTransaction, Supplier, db
from tests.cleanup import purge  # UNPOST-001 U3: cleanup of posted rows is a purge

EARN = 'عمولة فرق العيار'
PAY = 'رسوم فرق العيار'
GOLD24K = 'عمولة السداد بذهب صافي'


def _uid():
    return uuid.uuid4().hex[:8]


@pytest.fixture
def unposted_purchase():
    """make(**invoice fields) -> (invoice id, supplier account id); rows removed afterwards."""
    made = []

    def make(**fields):
        with flask_app.app_context():
            account = Account(account_number=f'96{_uid()[:4]}', name=f'مورد {_uid()}', type='Liability')
            db.session.add(account)
            db.session.flush()
            supplier = Supplier(supplier_code=f'S-{_uid()}', name=f'مورد {_uid()}', account_id=account.id)
            db.session.add(supplier)
            db.session.flush()
            invoice = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
                              supplier_id=supplier.id, date=datetime.now(), total=1000.0,
                              status='unpaid', amount_paid=0.0, is_posted=False, **fields)
            db.session.add(invoice)
            db.session.commit()
            made.append((invoice.id, supplier.id, account.id))
            return invoice.id, account.id

    yield make
    with flask_app.app_context():
        for invoice_id, supplier_id, account_id in made:
            entry_ids = [je.id for je in JournalEntry.query.filter_by(reference_type='invoice',
                                                                      reference_id=invoice_id).all()]
            if entry_ids:
                JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entry_ids)).delete(
                    synchronize_session=False)
                purge(lambda: JournalEntry.query.filter(JournalEntry.id.in_(entry_ids)).delete(synchronize_session=False))
            SafeBoxTransaction.query.filter_by(invoice_id=invoice_id).delete(synchronize_session=False)
            purge(lambda: Invoice.query.filter_by(id=invoice_id).delete(synchronize_session=False))
            Supplier.query.filter_by(id=supplier_id).delete(synchronize_session=False)
            Account.query.filter_by(id=account_id).delete(synchronize_session=False)
        db.session.commit()


def _post(invoice_id, auth_headers):
    resp = flask_app.test_client().post(f'/api/invoices/post/{invoice_id}', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.get_data(as_text=True)


def _entries(invoice_id, prefix):
    """[(is_posted, {(account_id, debit, credit), ...})] for the invoice's entries starting with prefix."""
    with flask_app.app_context():
        found = JournalEntry.query.filter(JournalEntry.reference_type == 'invoice',
                                          JournalEntry.reference_id == invoice_id,
                                          JournalEntry.description.like(f'{prefix}%')).all()
        return [(bool(je.is_posted),
                 {(line.account_id, round(line.cash_debit or 0, 2), round(line.cash_credit or 0, 2))
                  for line in je.lines if not line.is_deleted})
                for je in found]


def _revenue_account():
    from accounting.wages import _ensure_gold24k_commission_revenue_account
    with flask_app.app_context():
        account_id = _ensure_gold24k_commission_revenue_account()
        db.session.commit()
        return account_id


def _expense_account():
    from routes.invoices import _ensure_karat_diff_expense_account
    with flask_app.app_context():
        account_id = _ensure_karat_diff_expense_account()
        db.session.commit()
        return account_id


def test_a_karat_difference_the_shop_earns_is_charged_to_the_supplier(unposted_purchase, auth_headers):
    """The shape of invoice 3020: earn 307.37 -> Dr supplier / Cr commission revenue, posted."""
    invoice_id, supplier_account = unposted_purchase(karat_diff_earn_total=307.37)
    revenue = _revenue_account()
    _post(invoice_id, auth_headers)
    assert _entries(invoice_id, EARN) == [(True, {(supplier_account, 307.37, 0), (revenue, 0, 307.37)})]


def test_a_karat_difference_the_shop_pays_is_owed_to_the_supplier(unposted_purchase, auth_headers):
    invoice_id, supplier_account = unposted_purchase(karat_diff_pay_total=50.0)
    expense = _expense_account()
    _post(invoice_id, auth_headers)
    assert _entries(invoice_id, PAY) == [(True, {(expense, 50.0, 0), (supplier_account, 0, 50.0)})]


def test_a_24k_settlement_commission_is_charged_to_the_supplier(unposted_purchase, auth_headers):
    invoice_id, supplier_account = unposted_purchase(gold24k_settlement=True, gold24k_weight=10.0,
                                                     gold24k_commission_per_gram=12.0,
                                                     gold24k_commission_total=120.0)
    revenue = _revenue_account()
    _post(invoice_id, auth_headers)
    assert _entries(invoice_id, GOLD24K) == [(True, {(supplier_account, 120.0, 0), (revenue, 0, 120.0)})]


def test_an_invoice_with_neither_gets_no_such_entry(unposted_purchase, auth_headers):
    invoice_id, _ = unposted_purchase()
    _post(invoice_id, auth_headers)
    assert _entries(invoice_id, EARN) == _entries(invoice_id, PAY) == _entries(invoice_id, GOLD24K) == []
