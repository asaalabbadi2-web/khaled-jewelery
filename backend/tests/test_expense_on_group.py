"""An expense booked on a group account, moved to its own account (the owner, 17 Nov 2026).

JE-2026-02177 debited 1,000 riyals to «5 المصروفات» itself; the owner named
its account: «5470 رواتب المحاسبين والأداريين». The correction:
  - one entry, dated as the voucher, the group's line reversed onto the account
    named, its own riyals; the group holds nothing of it after; once;
  - refused, writing nothing, when the account named has accounts under it,
    or is not on the group's side, or the line carries grams.

Run:
    python -m pytest tests/test_expense_on_group.py -v
"""
import datetime as dt
import uuid

import pytest

from accounting.chart_tree import EXPENSES_ROOT, REVENUE_ROOT, role_account_id
from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db

NOW = dt.datetime(2026, 11, 17, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _account(parent_id, kind='Expense'):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name=f'حساب {uuid.uuid4().hex[:5]}', type=kind,
                parent_id=parent_id, tracks_weight=False)
    db.session.add(a)
    db.session.flush()
    return a


def _booked_on_the_group(**group_line):
    """Booked, then an account put under it -- as on production; a group takes
    no posting since (parent_account_guard, 18 Nov 2026)."""
    group = _account(role_account_id(EXPENSES_ROOT))
    cash = _account(None, 'Asset')
    je = JournalEntry(entry_number=f'JE-EG-{uuid.uuid4().hex[:6]}', date=dt.datetime(2026, 5, 15, 13, 0),
                      description='نقد', entry_type='عادي', is_posted=True, is_draft=False, is_deleted=False,
                      created_by='admin')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=group.id, cash_debit=1000.0, **group_line),
                        JournalEntryLine(journal_entry_id=je.id, account_id=cash.id, cash_credit=1000.0)])
    db.session.flush()
    salaries = _account(group.id)
    return je, group, salaries


def _cash(account):
    rows = JournalEntryLine.query.filter_by(account_id=account.id).filter(JournalEntryLine.is_deleted.isnot(True))
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in rows), 2)


def test_the_riyals_move_to_the_account_named_dated_as_the_voucher_once():
    from services.repair.expense_on_group import MOVED, move
    je, group, salaries = _booked_on_the_group()
    done = move(by='t', now=NOW, entry_number=je.entry_number, from_number=group.account_number,
                to_number=salaries.account_number)
    assert (done['date'], done['cash_debit']) == ('2026-05-15', 1000.0)
    assert (_cash(group), _cash(salaries)) == (0.0, 1000.0)
    written = JournalEntry.query.filter_by(reference_type=MOVED, reference_id=je.id).one()
    assert written.date == je.date and written.is_posted
    again = move(by='t', now=NOW, entry_number=je.entry_number, from_number=group.account_number,
                 to_number=salaries.account_number)
    assert again['already'] is True


def test_not_to_a_group_nor_across_sides_nor_with_grams():
    from services.repair.expense_on_group import MOVED, NotAsFound, move
    je, group, salaries = _booked_on_the_group()
    _account(salaries.id)                                                 # salaries is a group now
    with pytest.raises(NotAsFound, match='a group itself'):
        move(by='t', now=NOW, entry_number=je.entry_number, from_number=group.account_number,
             to_number=salaries.account_number)
    revenue = _account(role_account_id(REVENUE_ROOT), 'Revenue')
    with pytest.raises(NotAsFound, match='side'):
        move(by='t', now=NOW, entry_number=je.entry_number, from_number=group.account_number,
             to_number=revenue.account_number)
    je2, group2, salaries2 = _booked_on_the_group(debit_21k=1.0)
    with pytest.raises(NotAsFound, match='grams'):
        move(by='t', now=NOW, entry_number=je2.entry_number, from_number=group2.account_number,
             to_number=salaries2.account_number)
    assert JournalEntry.query.filter(JournalEntry.reference_type == MOVED,
                                     JournalEntry.reference_id.in_([je.id, je2.id])).count() == 0


def test_the_night_says_a_group_holding_riyals_of_its_own_and_not_once_moved():
    from services.books_invariants import GROUP_ACCOUNT_POSTED, check_group_accounts_posted
    from services.repair.expense_on_group import move
    je, group, salaries = _booked_on_the_group()
    found = {f.subject_key: f for f in check_group_accounts_posted()}
    assert found[f'account:{group.id}'].metric == 1000.0 and found[f'account:{group.id}'].kind == GROUP_ACCOUNT_POSTED
    assert f'account:{salaries.id}' not in found, 'not a group'
    move(by='t', now=NOW, entry_number=je.entry_number, from_number=group.account_number,
         to_number=salaries.account_number)
    assert f'account:{group.id}' not in {f.subject_key for f in check_group_accounts_posted()}
