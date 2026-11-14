"""Before a month is closed, and every night after (ADR-090, phase 6).

The owner (14 Nov 2026): «الفحص يكتشف ويبلّغ، أما التصحيح فيمر عبر إجراء
محاسبي مصرح به.» Two nightly checks (law 8) that report and never write: the
two accounts against the expenses' balances, and the months over that are not
posted. And before the lock moves forward (law 9): what still waits in the
months it closes -- each would be refused there once closed -- refuses the
move, unless the owner accepts it by name, kept with the move.

Run:
    python -m pytest tests/test_period_lock_pending.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from models import Invoice, JournalEntry, JournalEntryLine, PeriodLock, db
from services.books_invariants import (
    PERIOD_EXPENSE_LEDGER_DRIFT, PERIOD_EXPENSE_MONTH_MISSING,
    check_period_expense_ledger_drift, check_period_expense_months_missing,
)
from services.period_expense import accrue
from services.period_lock import PeriodLockRefused, move, pending
from tests.period_expense_world import books, expense, pay  # noqa: F401 (fixture)
from tests.voucher_world import auto_post, create, vworld  # noqa: F401 (fixture)

NOW = datetime(2026, 11, 14, 10, 0)
OCTOBER = date(2026, 10, 31)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _posted_entry(day, account_id, other_id, amount=50.0):
    je = JournalEntry(entry_number=f'PP-{uuid.uuid4().hex[:8]}', date=datetime.combine(day, datetime.min.time()),
                      description='يدوي', is_posted=True)
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=account_id, cash_debit=amount),
                        JournalEntryLine(journal_entry_id=je.id, account_id=other_id, cash_credit=amount)])
    db.session.flush()
    return je


# ── law 8: the nightly checks ─────────────────────────────────────────────────

def test_the_ledger_and_the_expenses_agree_and_a_manual_entry_is_reported(books):
    expense(books, amount=1200, description='رخصة')
    accrue(date(2026, 3, 31), by='t', now=NOW, dry_run=False)
    assert check_period_expense_ledger_drift() == []
    _posted_entry(date(2026, 2, 10), books['prepaid'], books['cash'])
    facts = check_period_expense_ledger_drift()
    assert [(f.kind, f.subject_key, f.metric) for f in facts] == [
        (PERIOD_EXPENSE_LEDGER_DRIFT, f"account:{books['prepaid']}", 50.0)]


def test_a_payment_cancelled_after_installments_is_reported_until_reclassified(auth_headers, books):
    auto_post(True)
    licence = expense(books, amount=1200, description='رخصة')
    vid = pay(auth_headers, books, licence, 1200, date(2026, 1, 1)).get_json()['id']
    accrue(date(2026, 10, 31), by='t', now=NOW, dry_run=False)
    g.pop('current_user', None)
    flask_app.test_client().post(f'/api/vouchers/{vid}/cancel', headers=auth_headers, json={'reason': 'خطأ'})
    assert {f.subject_key for f in check_period_expense_ledger_drift()} == {
        f"account:{books['prepaid']}", f"account:{books['accrued']}"}
    accrue(date(2026, 11, 30), by='t', now=NOW, dry_run=False)         # the month's run reclassifies
    assert check_period_expense_ledger_drift() == []


def test_months_the_books_moved_past_unposted_are_reported(books, monkeypatch):
    """The books' today fixed here: the shared test database holds other tests' entries."""
    import services.period_expense as period_expense
    rent = expense(books)
    accrue(date(2026, 5, 31), by='t', now=NOW, dry_run=False)
    monkeypatch.setattr(period_expense, 'books_today', lambda: date(2026, 6, 10))
    assert [f for f in check_period_expense_months_missing() if f.subject_key == f'period_expense:{rent.id}'] == []
    monkeypatch.setattr(period_expense, 'books_today', lambda: date(2026, 8, 15))   # the books reach August
    facts = [f for f in check_period_expense_months_missing() if f.subject_key == f'period_expense:{rent.id}']
    assert [(f.kind, f.metric) for f in facts] == [(PERIOD_EXPENSE_MONTH_MISSING, 24150.0)]   # June and July
    accrue(date(2026, 7, 31), by='t', now=NOW, dry_run=False)
    assert [f for f in check_period_expense_months_missing() if f.subject_key == f'period_expense:{rent.id}'] == []


def test_the_books_today_is_their_last_posted_entry_not_a_clock(books):
    from services.period_expense import books_today
    _posted_entry(date(2099, 1, 15), books['cash'], books['supplier_acc'])
    assert books_today() == date(2099, 1, 15)


def test_the_checks_write_nothing(books):
    expense(books, amount=1200, description='رخصة')
    _posted_entry(date(2026, 8, 15), books['prepaid'], books['cash'])
    before = (JournalEntry.query.count(), JournalEntryLine.query.count())
    assert check_period_expense_ledger_drift() and check_period_expense_months_missing()
    assert (JournalEntry.query.count(), JournalEntryLine.query.count()) == before


# ── law 9: what waits before a close ──────────────────────────────────────────

def test_what_waits_in_the_months_is_listed_and_refuses_the_close(auth_headers, books):
    auto_post(False)
    voucher_id = create(auth_headers, books, 'cash_payment')                 # pending, dated 1 Oct 2026
    draft = JournalEntry(entry_number='PP-DRAFT', date=datetime(2026, 10, 5), description='مسودة', is_draft=True)
    invoice = Invoice(invoice_type_id=987001, invoice_type='شراء', date=datetime(2026, 10, 7), total=10.0,
                      status='unpaid', amount_paid=0.0, is_posted=False)
    retracted = Invoice(invoice_type_id=987002, invoice_type='شراء', date=datetime(2026, 10, 8), total=10.0,
                        status='rejected', amount_paid=0.0, is_posted=False)
    db.session.add_all([draft, invoice, retracted])
    db.session.flush()
    left = JournalEntry(entry_number='PP-LEFT', date=datetime(2026, 10, 8), description='مسودة فاتورة مرفوضة',
                        is_draft=True, reference_type='invoice', reference_id=retracted.id)
    # its payment's draft too, as JE-2026-05978 of 3123 (the owner: «لا يجب ان ترحل»)
    paid = JournalEntry(entry_number='PP-PAID', date=datetime(2026, 9, 26), description='دفعات فاتورة مرفوضة',
                        is_draft=True, reference_type='invoice_payments', reference_id=retracted.id)
    db.session.add_all([left, paid])
    db.session.flush()
    rent = expense(books)
    waiting = pending(None, OCTOBER)
    assert [v['id'] for v in waiting['vouchers']['items']] == [voucher_id]
    assert 'PP-DRAFT' in [e['number'] for e in waiting['entries']['items']]
    assert {'PP-LEFT', 'PP-PAID'}.isdisjoint(e['number'] for e in waiting['entries']['items'])   # a rejected invoice's
    assert [i['id'] for i in waiting['invoices']['items']] == [invoice.id]       # not the rejected one
    assert [p['period_expense_id'] for p in waiting['period_expenses']['items']] == [rent.id]
    with pytest.raises(PeriodLockRefused) as refused:
        move(OCTOBER, reason='إقفال أكتوبر', by='owner', now=NOW)
    assert refused.value.code == 'pending_in_period' and refused.value.detail['total'] == waiting['total']
    assert PeriodLock.query.count() == 0


def test_the_owner_may_accept_what_waits_by_name_and_it_is_kept(books):
    rent = expense(books)
    row = move(OCTOBER, reason='إقفال أكتوبر', by='owner', now=NOW, accept_pending=True)
    kept = json.loads(row.accepted_pending)
    assert [p['period_expense_id'] for p in kept['period_expenses']['items']] == [rent.id]
    assert row.to_dict()['accepted_pending']['total'] == kept['total']


def test_with_nothing_waiting_the_month_closes_and_moving_back_asks_nothing(books):
    expense(books, amount=1200, start=date(2026, 1, 1), end=date(2026, 12, 31), description='رخصة')
    accrue(OCTOBER, by='t', now=NOW, dry_run=False)
    row = move(OCTOBER, reason='إقفال أكتوبر', by='owner', now=NOW)
    assert row.accepted_pending is None
    assert move(date(2026, 9, 30), reason='تصحيح', by='owner', now=NOW).accepted_pending is None


def test_only_the_months_the_move_closes_are_asked(books):
    """A draft left in September, accepted when September closed, is not asked again for October."""
    expense(books, amount=1200, start=date(2026, 1, 1), end=date(2026, 12, 31), description='رخصة')
    db.session.add(JournalEntry(entry_number='PP-OLD', date=datetime(2026, 9, 5), description='قديمة', is_draft=True))
    db.session.flush()
    accrue(date(2026, 9, 30), by='t', now=NOW, dry_run=False)
    move(date(2026, 9, 30), reason='إقفال سبتمبر', by='owner', now=NOW, accept_pending=True)
    accrue(OCTOBER, by='t', now=NOW, dry_run=False)
    assert pending(date(2026, 9, 30), OCTOBER)['total'] == 0
    assert move(OCTOBER, reason='إقفال أكتوبر', by='owner', now=NOW).accepted_pending is None


def test_the_routes_preview_and_refuse_with_what_waits(auth_headers, books):
    expense(books)
    client = flask_app.test_client()
    g.pop('current_user', None)
    preview = client.get('/api/period-lock/pending?through=2026-10-31', headers=auth_headers).get_json()
    assert preview['period_expenses']['count'] == 1 and preview['after'] is None
    g.pop('current_user', None)
    refused = client.post('/api/period-lock', headers=auth_headers,
                          json={'closed_through': '2026-10-31', 'reason': 'إقفال أكتوبر'})
    assert refused.status_code == 409 and refused.get_json()['pending']['total'] == preview['total']
    g.pop('current_user', None)
    accepted = client.post('/api/period-lock', headers=auth_headers,
                           json={'closed_through': '2026-10-31', 'reason': 'إقفال أكتوبر', 'accept_pending': True})
    assert accepted.status_code == 201 and accepted.get_json()['accepted_pending']['total'] == preview['total']
