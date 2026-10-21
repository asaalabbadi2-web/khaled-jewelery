"""The supplier ledger endpoint: its summary, movements, date filter and pages.

Brought in from the root (TEST-003): it built its own Flask app on an
in-memory SQLite with only the old `api` blueprint, so since the route moved
to suppliers_bp it answered 404 -- unseen, the gate never ran it. The same
three checks, on the app and the run's PostgreSQL, behind the fence.

Run:
    python -m pytest tests/test_supplier_ledger_endpoint.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, Supplier, db


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


@pytest.fixture
def supplier():
    payable = Account(account_number=f'21{uuid.uuid4().int % 10**6:06d}', name='دائنون اختبار', type='Liability',
                      transaction_type='both', tracks_weight=True)
    db.session.add(payable)
    db.session.flush()
    s = Supplier(supplier_code=f'S-{uuid.uuid4().hex[:6]}', name=f'مورد {uuid.uuid4().hex[:6]}', account_id=payable.id)
    db.session.add(s)
    db.session.flush()
    _entry(s, payable, datetime(2025, 1, 1, 10, 0), cash_debit=500.0, gold_21k=5.0)
    return s, payable


def _entry(supplier, account, when, *, cash_debit, gold_21k=0.0):
    other = Account(account_number=f'19{uuid.uuid4().int % 10**6:06d}', name='مقابل', type='Asset',
                    transaction_type='both', tracks_weight=True)
    db.session.add(other)
    db.session.flush()
    je = JournalEntry(entry_number=f'JE-SL-{uuid.uuid4().hex[:8]}', date=when, description='قيد',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id, supplier_id=supplier.id,
                         cash_debit=cash_debit, debit_21k=gold_21k, description='قيد'),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_credit=cash_debit,
                         credit_21k=gold_21k, description='قيد'),
    ])
    db.session.flush()


def _ledger(headers, supplier, **query):
    resp = flask_app.test_client().get(f'/api/suppliers/{supplier.id}/ledger', query_string=query, headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_the_ledger_returns_its_summary_and_movements(auth_headers, supplier):
    s, payable = supplier
    data = _ledger(auth_headers, s)
    assert data['summary']['total_debits']['cash'] == 500.0
    assert data['pagination']['total_items'] == 1
    (movement,) = data['movements']
    assert movement['account_name'] == payable.name
    assert movement['gold_21k_debit'] == pytest.approx(5.0)


def test_a_date_after_the_entries_leaves_nothing(auth_headers, supplier):
    data = _ledger(auth_headers, supplier[0], date_from='2025-02-01')
    assert data['pagination']['total_items'] == 0
    assert data['movements'] == []


def test_the_ledger_is_paged(auth_headers, supplier):
    s, payable = supplier
    _entry(s, payable, datetime(2025, 2, 1, 12, 0), cash_debit=250.0, gold_21k=2.0)
    data = _ledger(auth_headers, s, per_page=1)
    assert data['pagination']['total_pages'] == 2
    assert data['pagination']['total_items'] == 2
