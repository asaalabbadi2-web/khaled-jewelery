"""An expense posted on the wrong account, moved by an entry at its voucher's date (the owner, 5 Nov 2026).

The owner: «ينقل» -- the workers' housing rent was paid by four vouchers
(PV-2026-00544, -00938, -01118, -01339; 1,750.00 on the 2 Nov copy) posted
on the salaries account 5410. services/repair/voucher_expense_reclass moves
each named voucher's amount on one account to another the owner made, by an
entry dated the voucher's own (the months stay right), with an audit row --
once; dry by default; a target that is no expense account is refused.

Run:
    python -m pytest tests/test_voucher_expense_reclass.py -v
"""
import datetime as dt
import uuid

import pytest

from models import Account, JournalEntry, JournalEntryLine, Voucher, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number, kind='Expense'):
    a = Account(account_number=number, name=f'حساب {number}', type=kind)
    db.session.add(a)
    db.session.flush()
    return a


@pytest.fixture
def paid():
    n = uuid.uuid4().int % 10**5
    salaries, rent, cash = _account(f'54{n:05d}1'), _account(f'54{n:05d}2'), _account(f'11{n:05d}', 'Asset')
    entry = JournalEntry(entry_number=f'JE-R-{n}', date=dt.datetime(2041, 6, 10, 11), description='صرف أجار عزبة',
                         entry_type='عادي', is_posted=True, is_draft=False, created_by='t',
                         reference_type='voucher', reference_id=0)
    db.session.add(entry)
    db.session.flush()
    voucher = Voucher(voucher_number=f'PV-R-{n}', voucher_type='payment', date=entry.date, status='approved',
                      created_by='t', journal_entry_id=entry.id)
    db.session.add(voucher)
    db.session.flush()
    entry.reference_id = voucher.id
    for account, debit, credit in ((salaries, 250.0, 0.0), (cash, 0.0, 250.0)):
        db.session.add(JournalEntryLine(journal_entry_id=entry.id, account_id=account.id, cash_debit=debit,
                                        cash_credit=credit, description='أجار'))
    db.session.flush()
    return {'voucher': voucher, 'salaries': salaries, 'rent': rent, 'cash': cash}


def _moved(account):
    return float(db.session.query(db.func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
                 .filter(JournalEntryLine.account_id == account.id).scalar() or 0.0)


def test_each_voucher_s_amount_moves_at_its_date_once(paid):
    from models import AuditLog
    from services.repair.voucher_expense_reclass import reclassify
    args = dict(voucher_numbers=[paid['voucher'].voucher_number], from_number=paid['salaries'].account_number,
                to_number=paid['rent'].account_number, by='t', now=dt.datetime(2041, 7, 1))
    plan = reclassify(**args)
    assert [r['amount'] for r in plan['moved']] == [250.0] and _moved(paid['rent']) == 0.0, 'dry by default'
    reclassify(**args, dry_run=False)
    assert _moved(paid['rent']) == 250.0 and _moved(paid['salaries']) == 0.0
    entry = JournalEntry.query.filter_by(reference_type='expense_reclassification',
                                         reference_id=paid['voucher'].id).one()
    assert entry.date == dt.datetime(2041, 6, 10, 11), 'the voucher\'s month'
    assert AuditLog.query.filter_by(action='repair_voucher_expense_reclass').count() >= 1
    assert reclassify(**args, dry_run=False)['moved'] == [], 'once'


def test_a_target_that_is_no_expense_is_refused(paid):
    from services.repair.voucher_expense_reclass import ReclassRefused, reclassify
    with pytest.raises(ReclassRefused):
        reclassify(voucher_numbers=[paid['voucher'].voucher_number], from_number=paid['salaries'].account_number,
                   to_number=paid['cash'].account_number, by='t', now=dt.datetime(2041, 7, 1),
                   dry_run=False)
    with pytest.raises(ReclassRefused):
        reclassify(voucher_numbers=[paid['voucher'].voucher_number], from_number=paid['salaries'].account_number,
                   to_number='99999999', by='t', now=dt.datetime(2041, 7, 1), dry_run=False)
