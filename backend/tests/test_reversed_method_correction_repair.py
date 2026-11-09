"""The payment-method correction written backwards, set right (the owner, 9 Nov 2026: «أ»).

As production on 8 Nov: a purchase paid 1,000 from the cash box, its method
put right to the bank by the code before the fix -- the cash box credited
again, the bank debited. Both accounts protected, as the main cash and the
Riyadh bank are. The repair reverses the wrong entry and writes the right
one: the cash box back to nil, the bank -1,000 -- the books where the safe
rows always were. Dry run writes nothing; a second run finds nothing; the
protection stands for every other write.

Run:
    python -m pytest tests/test_reversed_method_correction_repair.py -v
"""
import pytest

from models import Account, JournalEntry, JournalEntryLine, SafeBoxTransaction, db
from services.repair.entries import ProtectedAccount, write_entry
from services.repair.reversed_method_corrections import set_reversed_corrections_right
from tests.test_outgoing_payment_correction import _cash, _rows, paid  # noqa: F401
from tests.test_supplier_purchase_effect import _vat, app, rollback_after_each, world  # noqa: F401
from tests.test_stock_count import NOW


@pytest.fixture
def backwards(paid):
    """The correction as the code before the fix wrote it."""
    ip, cash, bank = paid['payment'], paid['cash'], paid['bank']
    ip.payment_method_id = paid['bank_pm'].id
    SafeBoxTransaction.query.filter_by(invoice_payment_id=ip.id).one().safe_box_id = bank.id
    je = JournalEntry(entry_number='JE-WRONG-1', date=NOW, description='إعادة تصنيف وسيلة دفع', entry_type='عادي',
                      reference_type='payment_method_correction', reference_id=ip.id, is_posted=True,
                      is_draft=False, created_by='admin')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=bank.account_id, cash_debit=1000.0),
                        JournalEntryLine(journal_entry_id=je.id, account_id=cash.account_id, cash_credit=1000.0)])
    for box in (cash, bank):
        db.session.get(Account, box.account_id).repair_protected = True
    db.session.flush()
    assert (_cash(cash.account_id), _cash(bank.account_id)) == (-2000.0, 1000.0), 'as production: 2x off'
    assert (_rows(cash), _rows(bank)) == (0.0, -1000.0), 'the safe rows right'
    return paid


def test_the_dry_run_names_it_and_writes_nothing(backwards):
    entries = JournalEntry.query.count()
    result = set_reversed_corrections_right(by='t', now=NOW)
    assert [c['entry'] for c in result['corrections']] == ['JE-WRONG-1'] and result['dry_run']
    assert JournalEntry.query.count() == entries


def test_applied_the_books_are_where_the_safe_rows_were(backwards):
    cash, bank = backwards['cash'], backwards['bank']
    rows_before = SafeBoxTransaction.query.count()
    result = set_reversed_corrections_right(by='t', now=NOW, dry_run=False)
    assert result['count'] == 1 and result['corrections'][0]['reversal'].startswith('REV')
    assert (_cash(cash.account_id), _cash(bank.account_id)) == (0.0, -1000.0)
    assert (_rows(cash), _rows(bank)) == (0.0, -1000.0) and SafeBoxTransaction.query.count() == rows_before
    assert set_reversed_corrections_right(by='t', now=NOW, dry_run=False)['count'] == 0, 'a second run: nothing'


def test_the_protection_stands_for_every_other_write(backwards):
    with pytest.raises(ProtectedAccount):
        write_entry(date=NOW, description='x', reference_type='t', reference_id=1, by='t', now=NOW,
                    lines=[{'account_id': backwards['cash'].account_id, 'cash_debit': 1.0},
                           {'account_id': backwards['bank'].account_id, 'cash_credit': 1.0}])


def test_money_received_corrected_is_not_touched(paid):
    """A sale's correction («credit old, debit new») is right: not found."""
    ip = paid['payment']
    SafeBoxTransaction.query.filter_by(invoice_payment_id=ip.id).one().direction = 'in'
    ip.payment_method_id = paid['bank_pm'].id
    je = JournalEntry(entry_number='JE-RIGHT-1', date=NOW, description='x', entry_type='عادي',
                      reference_type='payment_method_correction', reference_id=ip.id, is_posted=True,
                      is_draft=False, created_by='admin')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=paid['bank'].account_id, cash_debit=5.0),
                        JournalEntryLine(journal_entry_id=je.id, account_id=paid['cash'].account_id, cash_credit=5.0)])
    db.session.flush()
    assert set_reversed_corrections_right(by='t', now=NOW)['count'] == 0
