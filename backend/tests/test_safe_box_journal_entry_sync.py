"""A posted entry's safe-box rows: a system entry's, once; a manual entry's, none.

Brought in from the root (TEST-003). It pinned the old rule -- a manual entry
moved its safe -- which accounting/safe_boxes.py reversed on purpose: a manual
entry is an internal transfer, not a physical movement of cash or gold; only
system entries (invoice, voucher, shift) make safe-box rows. And its fixture
ran db.create_all()/db.drop_all() on the run's database: in the gate it would
have dropped every table under the tests after it. Rewritten on the app,
behind the fence.

Run:
    python -m pytest tests/test_safe_box_journal_entry_sync.py -v
"""
import uuid

import pytest

from accounting.safe_boxes import _rebuild_safe_box_transactions_for_journal_entry
from models import Account, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, db


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _entry(reference_type):
    acc = Account(account_number=f'11{uuid.uuid4().int % 10**6:06d}', name='صندوق اختبار', type='Asset')
    db.session.add(acc)
    db.session.flush()
    safe = SafeBox(name=f'خزينة {uuid.uuid4().hex[:6]}', safe_type='cash', account_id=acc.id, is_active=True)
    je = JournalEntry(entry_number=f'JE-SB-{uuid.uuid4().hex[:8]}', description='قيد', is_draft=False,
                      is_posted=True, reference_type=reference_type, reference_id=1 if reference_type else None)
    db.session.add_all([safe, je])
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=acc.id, cash_debit=100.0, cash_credit=0.0)
    db.session.add(line)
    db.session.flush()
    return safe, je, line


def _rows(je):
    return SafeBoxTransaction.query.filter_by(ref_type='journal_entry', ref_id=je.id).all()


def test_a_system_entry_moves_its_safe_once():
    safe, je, line = _entry('voucher')
    _rebuild_safe_box_transactions_for_journal_entry(je, [line], created_by='test')
    db.session.flush()
    (row,) = _rows(je)
    assert (row.safe_box_id, row.direction, float(row.amount_cash)) == (safe.id, 'in', 100.0)
    _rebuild_safe_box_transactions_for_journal_entry(je, [line], created_by='test')   # idempotent
    db.session.flush()
    assert len(_rows(je)) == 1


@pytest.mark.parametrize('reference_type', [None, 'manual', 'journal_entry'])
def test_a_manual_entry_moves_no_safe(reference_type):
    _, je, line = _entry(reference_type)
    _rebuild_safe_box_transactions_for_journal_entry(je, [line], created_by='test')
    db.session.flush()
    assert _rows(je) == []
