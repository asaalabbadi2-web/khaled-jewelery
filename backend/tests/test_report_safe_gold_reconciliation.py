"""The gold safes' statements against the books, karat by karat, on a day (REPORTS ت5-3, ADR-083).

«ميزان مراجعة الأوزان (خزنة ↔ حساب)» computed its own: every statement row,
and the account's lines with no regard to whether they count (a deleted or
unposted entry was summed), its end day cut at midnight (an entry dated that
day after 00:00 fell out). This reads what the nightly check reads
(services/safebox_subledger.gold_subledger_by_box: the statement rows the
check counts against the posted, not-deleted entries on the safe's account),
now to the end of a day: per gold safe its main-karat totals, then each karat
-- the statement, the books, the difference. Its check is the nightly one's
threshold (0.01 g).

Run:
    python -m pytest tests/test_report_safe_gold_reconciliation.py -v
"""
import datetime as dt

import pytest

from models import JournalEntry, JournalEntryLine, SafeBoxTransaction, db
from tests.test_books_invariants import _gold_safe, _uid

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _row(box, grams, when, karat=21):
    db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='invoice_gold', ref_id=1, direction='in',
                                      amount_cash=0.0, **{f'weight_{karat}k': grams}, created_at=when,
                                      created_by='t'))
    db.session.flush()


def _posted(box, grams, when, *, deleted=False, karat=21):
    je = JournalEntry(entry_number=f'JE-G-{_uid()}', date=when, description='ذهب', entry_type='عادي',
                      is_posted=True, is_deleted=deleted, reference_type='invoice', reference_id=1, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, description='ذهب',
                                    **{f'debit_{karat}k': grams}))
    db.session.flush()


def _report(day):
    from services.reports.safe_gold_reconciliation import safe_gold_reconciliation
    return safe_gold_reconciliation(as_of=day, now=D(2044, 2, 1))


def _lines(report, box):
    return {r['karat']: r for r in report.rows if r.get('safe_box_id') == box.id and r.get('karat')}


def test_each_karat_the_statement_the_books_and_their_difference():
    box = _gold_safe()
    _row(box, 10.0, D(2044, 1, 5, 10))
    _posted(box, 9.5, D(2044, 1, 5, 10))
    report = _report(dt.date(2044, 1, 31))
    line = _lines(report, box)['21k']
    assert (line['statement'], line['ledger'], line['difference']) == (10.0, 9.5, 0.5)
    assert {c.key: c.ok for c in report.checks} == {'statements_agree': False}


def test_a_deleted_entry_counts_on_neither_side_and_the_end_day_counts_whole():
    box = _gold_safe()
    _row(box, 4.0, D(2044, 1, 31, 18))
    _posted(box, 4.0, D(2044, 1, 31, 18))              # after midnight of the 31st: the old report lost it
    _posted(box, 7.0, D(2044, 1, 20, 9), deleted=True)
    report = _report(dt.date(2044, 1, 31))
    line = _lines(report, box)['21k']
    assert (line['statement'], line['ledger'], line['difference']) == (4.0, 4.0, 0.0)


def test_a_day_before_does_not_see_it():
    box = _gold_safe()
    _row(box, 3.0, D(2044, 1, 10, 12))
    _posted(box, 3.0, D(2044, 1, 10, 12))
    assert not _lines(_report(dt.date(2044, 1, 9)), box)
