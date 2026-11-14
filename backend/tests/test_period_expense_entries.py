"""A period expense's month entries, one rule for all (ADR-090, phase 4).

The owner (14 Nov 2026): «إذا تغيرت فترة المصروف أو قيمته بعد ترحيل بعض
الأشهر: لا تُعدّل القيود المرحلة، لا تُحذف القيود التاريخية، تُنشأ تسوية
للفروقات في فترة مفتوحة» -- the cumulative catch-up, option A. And «لا يجوز
للفحص الليلي أو إعادة تشغيل المحرك أن ينشئ قيوداً في شهر مغلق».

The rule: a month's entry is what the schedule has accrued by its end less what
the books have posted before it -- a month missed, an edit, a cancellation, a
closed month, each a difference the first open month takes whole.

Run:
    python -m pytest tests/test_period_expense_entries.py -v
"""
from datetime import date, datetime

import pytest
import sqlalchemy as sa
from flask import g

from app import app as flask_app
from models import JournalEntry, JournalEntryLine, db
from services.period_expense import (
    MONTH_ENTRY, PeriodExpenseRefused, accrue, cancel, edit, posted_accrual, values,
)
from services.period_lock import move
from tests.period_expense_world import books, debits, expense, pay  # noqa: F401 (fixture)
from tests.voucher_world import auto_post, vworld  # noqa: F401 (fixture)

NOW = datetime(2026, 11, 14, 10, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _run(through, dry_run=False):
    return accrue(through, by='tester', now=NOW, dry_run=dry_run)


def _entries(pe):
    return JournalEntry.query.filter_by(reference_type=MONTH_ENTRY, reference_id=pe.id).order_by(JournalEntry.date).all()


def _lines(entry):
    return {(l.account_id, round(l.cash_debit or 0, 2), round(l.cash_credit or 0, 2))
            for l in JournalEntryLine.query.filter_by(journal_entry_id=entry.id)}


def _balance(account_id, through):
    from services.period_expense import _ledger_balance, riyals
    return riyals(_ledger_balance(account_id, through))


# ── the month's entry ─────────────────────────────────────────────────────────

def test_each_month_its_entry_dated_its_last_day_and_a_second_run_writes_nothing(books):
    rent = expense(books)
    plan = _run(date(2026, 5, 31))
    assert [e['month'] for e in plan['entries']] == ['2026-01', '2026-02', '2026-03', '2026-04', '2026-05']
    entries = _entries(rent)
    assert [e.date.date() for e in entries][-1] == date(2026, 5, 31)
    assert _lines(entries[0]) == {(books['rent_account'], 12075.0, 0.0), (books['accrued'], 0.0, 12075.0)}
    assert all(e.is_posted for e in entries)
    assert _run(date(2026, 5, 31))['entries'] == []                     # again: nothing
    assert posted_accrual(rent, through=date(2026, 5, 31)) == 6037500


def test_a_preview_writes_nothing(books):
    rent = expense(books)
    plan = _run(date(2026, 3, 31), dry_run=True)
    assert len(plan['entries']) == 3 and _entries(rent) == []


def test_the_june_rent_from_accrued_through_prepaid_to_settled(auth_headers, books):
    """January to May accrued; 24 June pays them off and June ahead; June's
    entry draws the prepaid; July to October accrue again, the second half
    unpaid until December."""
    auto_post(True)
    rent = expense(books)
    _run(date(2026, 5, 31))
    pay(auth_headers, books, rent, 72450, date(2026, 6, 24))
    _run(date(2026, 6, 30))
    june = _entries(rent)[-1]
    assert _lines(june) == {(books['rent_account'], 12075.0, 0.0), (books['prepaid'], 0.0, 12075.0)}
    assert (_balance(books['prepaid'], date(2026, 6, 30)), _balance(books['accrued'], date(2026, 6, 30))) == (0.0, 0.0)
    _run(date(2026, 10, 31))
    assert _balance(books['accrued'], date(2026, 10, 31)) == -48300.0       # July-October, owed
    assert values(rent, date(2026, 10, 31))['balance'] == -48300.0           # the books and the expense agree


# ── law 7: an edit, a cancellation ────────────────────────────────────────────

def test_an_edit_after_posted_months_puts_the_whole_difference_in_the_next(books):
    rent = expense(books)
    _run(date(2026, 10, 31))
    posted = [(_lines(e), e.id) for e in _entries(rent)]
    edit(rent, reason='العقد الجديد', by='tester', now=NOW, amount=150000)
    plan = _run(date(2026, 11, 30))
    november = plan['entries'][-1]
    # 11 months of 150,000 / 12 = 137,500, less the 120,750 posted for January-October.
    assert (november['month'], november['amount'], november['scheduled']) == ('2026-11', 16750.0, 12500.0)
    assert [(_lines(e), e.id) for e in _entries(rent)][:10] == posted        # the posted months untouched
    from models import PeriodExpenseRevision
    revision = PeriodExpenseRevision.query.filter_by(period_expense_id=rent.id).one()
    assert revision.reason == 'العقد الجديد' and '144900' in revision.before and '150000' in revision.after


def test_a_shorter_period_accrues_the_rest_at_once_in_the_next_open_month(books):
    licence = expense(books, amount=1200, start=date(2026, 1, 1), end=date(2026, 12, 31), description='رخصة')
    _run(date(2026, 6, 30))                                                  # 600 posted
    edit(licence, reason='انتهت مبكرًا', by='tester', now=NOW, period_end=date(2026, 3, 31))
    plan = _run(date(2026, 7, 31))
    # The whole 1,200 now falls in January-March: the 600 not yet posted, in July whole.
    assert plan['entries'] == [{'period_expense_id': licence.id, 'month': '2026-07', 'amount': 600.0,
                                'scheduled': 0.0}]
    assert posted_accrual(licence, through=date(2026, 7, 31)) == 120000     # the whole 1,200 in three months


def test_a_cancelled_expense_takes_back_what_was_posted(books):
    subscription = expense(books, amount=1200, description='اشتراك')
    _run(date(2026, 3, 31))                                                  # 300 posted, accrued
    cancel(subscription, reason='أُلغي العقد', by='tester', now=NOW)
    plan = _run(date(2026, 4, 30))
    assert plan['entries'][-1]['amount'] == -300.0
    assert _lines(_entries(subscription)[-1]) == {(books['rent_account'], 0.0, 300.0), (books['accrued'], 300.0, 0.0)}
    assert posted_accrual(subscription, through=date(2026, 4, 30)) == 0


def test_an_expense_with_a_payment_standing_is_not_cancelled_nor_cut_below_it(auth_headers, books):
    auto_post(True)
    rent = expense(books)
    pay(auth_headers, books, rent, 72450, date(2026, 6, 24))
    for act, code in ((lambda: cancel(rent, reason='x', by='t', now=NOW), 'cancel_with_payments'),
                      (lambda: edit(rent, reason='x', by='t', now=NOW, amount=70000), 'amount_below_paid'),
                      (lambda: edit(rent, reason=' ', by='t', now=NOW, amount=150000), 'reason_required')):
        with pytest.raises(PeriodExpenseRefused) as refused:
            act()
        assert refused.value.code == code


# ── law 9: a closed month is not written ──────────────────────────────────────

def test_closed_months_are_not_written_the_first_open_one_takes_them(books):
    rent = expense(books)
    move(date(2026, 3, 31), reason='test', by='tester', now=NOW, accept_pending=True)   # its months, unposted
    plan = _run(date(2026, 4, 30))
    assert [(e['month'], e['amount']) for e in plan['entries']] == [('2026-04', 48300.0)]   # four months
    assert all(e.date.date() > date(2026, 3, 31) for e in _entries(rent))


# ── the two accounts: reclassified when the sum is right, reported when not ───

def test_a_payment_cancelled_after_installments_is_reclassified(auth_headers, books):
    auto_post(True)
    licence = expense(books, amount=1200, description='رخصة')
    vid = pay(auth_headers, books, licence, 1200, date(2026, 1, 1)).get_json()['id']
    assert debits(vid) == {(books['prepaid'], 1200.0)}
    _run(date(2026, 10, 31))                                                 # 1,000 drawn from the prepaid
    g.pop('current_user', None)
    assert flask_app.test_client().post(f'/api/vouchers/{vid}/cancel', headers=auth_headers,
                                        json={'reason': 'خطأ'}).status_code == 200
    plan = _run(date(2026, 11, 30))                                          # after the cancellation (today)
    assert plan['drift'] == [] and plan['reclass'] == [{'month': '2026-11', 'to_prepaid': 1000.0}]
    end = date(2026, 11, 30)
    assert (_balance(books['prepaid'], end), _balance(books['accrued'], end)) == (0.0, -1100.0)


def test_a_sum_the_expenses_do_not_explain_is_reported_not_written_over(books):
    from models import JournalEntry as JE
    expense(books, amount=1200, description='رخصة')
    stray = JE(entry_number='PE-STRAY', date=datetime(2026, 2, 10), description='يدوي', is_posted=True)
    db.session.add(stray)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=stray.id, account_id=books['prepaid'], cash_debit=50),
                        JournalEntryLine(journal_entry_id=stray.id, account_id=books['cash'], cash_credit=50)])
    db.session.flush()
    plan = _run(date(2026, 2, 28))
    assert plan['reclass'] == [] and plan['drift'][0]['month'] == '2026-02'


def test_the_database_holds_one_entry_a_month(books):
    rent = expense(books)
    _run(date(2026, 1, 31))
    sp = db.session.begin_nested()
    with pytest.raises(sa.exc.IntegrityError):
        db.session.add(JournalEntry(entry_number='PE-DUP', date=datetime(2026, 1, 31), description='dup',
                                    reference_type=MONTH_ENTRY, reference_id=rent.id, reference_number='2026-01'))
        db.session.flush()
    sp.rollback()


# ── the routes ────────────────────────────────────────────────────────────────

def test_the_month_end_action_previews_then_applies(auth_headers, books):
    rent = expense(books)
    client = flask_app.test_client()
    g.pop('current_user', None)
    preview = client.post('/api/period-expenses/accrue', headers=auth_headers, json={'through': '2026-02-28'})
    assert preview.status_code == 200 and len(preview.get_json()['entries']) == 2 and _entries(rent) == []
    g.pop('current_user', None)
    applied = client.post('/api/period-expenses/accrue', headers=auth_headers,
                          json={'through': '2026-02-28', 'apply': True})
    assert applied.status_code == 201 and len(_entries(rent)) == 2
    g.pop('current_user', None)
    future = client.post('/api/period-expenses/accrue', headers=auth_headers, json={'through': '2099-01-31'})
    assert future.status_code == 400 and future.get_json()['error'] == 'not_past'
