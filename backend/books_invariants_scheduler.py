"""Nightly books invariants — report what disagrees, touch nothing.

Runs services/books_invariants.run_books_invariants() once a day and commits the
findings it reconciles. It writes ONLY to reconciliation_findings.

RUN_AT is after the backup (02:00) and after the safe-box reconciliation job
(02:30), so the morning's findings describe the state that job left behind,
including any row its backfill wrote.

OPTIONAL, not critical (see schedulers.py): a report-only job must never be the
reason money stops moving. A failure to start is a WARNING; a failure during a
run is logged, rolled back, and the next night runs again.
"""
from __future__ import annotations

import time
from threading import Thread

import schedule


class BooksInvariantsScheduler:

    RUN_AT = "03:00"  # Server local time. After backup (02:00) and safe-box reconciliation (02:30).

    def __init__(self, app):
        self.app = app
        self.is_running = False
        self._scheduler = schedule.Scheduler()

    def run_once(self) -> dict:
        """One run, committed. Returns the per-kind buckets for the log."""
        from models import db
        from services.books_invariants import run_books_invariants

        with self.app.app_context():
            try:
                result = run_books_invariants()
                db.session.commit()
            except Exception:
                db.session.rollback()
                raise
        return result

    def job(self) -> None:
        tag = "[BooksInvariants]"
        try:
            result = self.run_once()
        except Exception as exc:
            print(f"{tag} run failed, rolled back: {exc}", flush=True)
            return
        # The morning's news is what OPENED or CHANGED. Persisting findings are
        # the known baseline; resolved ones are corrections that held.
        news = {
            kind: {'opened': len(b['opened']), 'changed': len(b['changed'])}
            for kind, b in result.items()
            if b['opened'] or b['changed']
        }
        if news:
            print(f"{tag} ⚠ NEW or CHANGED findings: {news}", flush=True)
        else:
            print(f"{tag} OK — nothing new or changed", flush=True)

    def _loop(self) -> None:
        while self.is_running:
            self._scheduler.run_pending()
            time.sleep(30)

    def start(self):
        if self.is_running:
            return self
        self.is_running = True
        self._scheduler.every().day.at(self.RUN_AT).do(self.job).tag("books_invariants")
        Thread(target=self._loop, name="BooksInvariantsScheduler", daemon=True).start()
        print(f"[BooksInvariantsScheduler] Started — runs daily at {self.RUN_AT} (server local time)")
        return self


def start_books_invariants_scheduler(app):
    return BooksInvariantsScheduler(app).start()
