"""The period expenses' months accrued every night (ADR-090, law 6).

The owner (14 Nov 2026): «آخر كل شهر: تشغّل استحقاق الشهر — اليس هذا من
عمل المجدول؟» -- «نعم». A month's entry is fixed by what was entered; nothing
waits for a judgement, and a month forgotten is an income statement short.

Run:
    python -m pytest tests/test_period_expense_scheduler.py -v
"""
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import JournalEntry, db
from period_expense_scheduler import BY, PeriodExpenseScheduler, last_month_end
from schedulers import _CRITICAL, _SCHEDULER_STARTERS
from services.period_expense import MONTH_ENTRY, posted_accrual
from tests.period_expense_world import books, expense  # noqa: F401 (fixture)
from tests.voucher_world import vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _entries(pe):
    return JournalEntry.query.filter_by(reference_type=MONTH_ENTRY, reference_id=pe.id).count()


def test_the_night_accrues_through_last_months_end_and_the_next_writes_nothing(app, books):
    rent = expense(books)
    job = PeriodExpenseScheduler(app)
    plan = job.run_once(now=datetime(2026, 11, 1, 2, 45))
    assert plan['through'] == '2026-10-31' and _entries(rent) == 10
    assert posted_accrual(rent, through=date(2026, 10, 31)) == 12075000
    assert {e.created_by for e in JournalEntry.query.filter_by(reference_type=MONTH_ENTRY)} == {BY}
    assert job.run_once(now=datetime(2026, 11, 2, 2, 45))['entries'] == []     # the next night: nothing


def test_an_expense_entered_late_is_accrued_the_next_night(app, books):
    job = PeriodExpenseScheduler(app)
    job.run_once(now=datetime(2026, 11, 1, 2, 45))
    late = expense(books, amount=1200, description='رخصة سُجّلت متأخرة')
    plan = job.run_once(now=datetime(2026, 11, 15, 2, 45))
    assert _entries(late) == 10 and len(plan['entries']) == 10


def test_a_database_with_no_period_expense_asks_nothing_not_even_the_roles(app):
    # no accounts mapped, no expense: the night passes, and says nothing
    assert PeriodExpenseScheduler(app).run_once(now=datetime(2026, 11, 1, 2, 45))['entries'] == []


def test_it_is_started_with_the_others_and_is_optional():
    assert 'period_expense' in _SCHEDULER_STARTERS and 'period_expense' not in _CRITICAL
    assert PeriodExpenseScheduler.RUN_AT < '03:00'          # before the books invariants read the months
    assert last_month_end(date(2026, 3, 1)) == date(2026, 2, 28)
