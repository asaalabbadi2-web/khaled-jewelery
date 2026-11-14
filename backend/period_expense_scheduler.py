"""Nightly accrual of the period expenses' months (ADR-090, law 6).

The owner (14 Nov 2026), asked whether the month-end accrual is a person's
job: a month's entry is fixed by what was entered -- the amount, the period --
so nothing at month's end waits for a judgement, and a month forgotten is an
income statement short. So the accrual runs itself: every night, through the
last day of the month before, by the one rule (services.period_expense.accrue).
It writes only on the night a month has ended -- or after an expense entered
late -- and nothing on the others: one entry an expense and month, held by
the database; never in a closed month (the period lock); never an entry
changed.

RUN_AT is before the books invariants (03:00), so the morning's check sees the
months this posted -- and a night it failed says so there
(PERIOD_EXPENSE_MONTH_MISSING), never silently.

OPTIONAL, not critical (see schedulers.py). The manual action on the screen
stays, for a preview or a run at once.
"""
from __future__ import annotations

import datetime as dt
import time
from threading import Thread

import schedule

BY = 'period_expense_scheduler'


def last_month_end(today: dt.date) -> dt.date:
    return today.replace(day=1) - dt.timedelta(days=1)


class PeriodExpenseScheduler:

    RUN_AT = "02:45"  # Server local time. Before the books invariants (03:00).

    def __init__(self, app):
        self.app = app
        self.is_running = False
        self._scheduler = schedule.Scheduler()

    def run_once(self, now: dt.datetime | None = None) -> dict:
        """One run through the last month's end, committed. *now* is the job's clock."""
        from models import db
        from services.period_expense import accrue

        now = now or dt.datetime.now()  # clock-guard: boundary
        with self.app.app_context():
            try:
                plan = accrue(last_month_end(now.date()), by=BY, now=now, dry_run=False)
                db.session.commit()
            except Exception:
                db.session.rollback()
                raise
        return plan

    def job(self) -> None:
        tag = "[PeriodExpense]"
        try:
            plan = self.run_once()
        except Exception as exc:
            print(f"{tag} run failed, rolled back (the morning's check will say which months wait): {exc}",
                  flush=True)
            return
        if plan['entries'] or plan['reclass']:
            print(f"{tag} accrued through {plan['through']}: {len(plan['entries'])} entries, "
                  f"{len(plan['reclass'])} reclass", flush=True)
        if plan['drift']:
            print(f"{tag} ⚠ the two accounts disagree with the expenses: {plan['drift']}", flush=True)

    def _loop(self) -> None:
        while self.is_running:
            self._scheduler.run_pending()
            time.sleep(30)

    def start(self):
        if self.is_running:
            return self
        self.is_running = True
        self._scheduler.every().day.at(self.RUN_AT).do(self.job).tag("period_expense")
        Thread(target=self._loop, name="PeriodExpenseScheduler", daemon=True).start()
        print(f"[PeriodExpenseScheduler] Started — runs daily at {self.RUN_AT} (server local time)")
        return self


def start_period_expense_scheduler(app):
    return PeriodExpenseScheduler(app).start()
