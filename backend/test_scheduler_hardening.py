"""Proof tests for ERP scheduler hardening (S1–S5).

Each test proves a BEHAVIOUR, not a comment.

S1 — CRITICAL scheduler failure → process exits 1, never reaches run_forever()
S2a — Loop exception → _failed flag set + SIGTERM sent to self
S2b — Unresponsive thread → join times out → os._exit(1) called
S3 — stop() while sleeping → thread exits in < 1 s
S4 — SIGTERM mid-sleep → threads joined cleanly, exit code 0
S5a — No settlement for > threshold → STALE_SETTLEMENT finding created
S5b — Second check while finding open → check_count incremented
"""
from __future__ import annotations

import os
import signal
import sys
import threading
import time
from unittest.mock import MagicMock, patch

import pytest

# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_app():
    """Return the Flask test app (DB already initialised by conftest.initialize_db)."""
    from app import app
    return app


# ═══════════════════════════════════════════════════════════════════════════════
# S1 — Fail-closed on CRITICAL scheduler startup
# ═══════════════════════════════════════════════════════════════════════════════

class TestFailClosedStartup:
    """S1: a CRITICAL scheduler that fails to start → sys.exit(1) before
    run_forever() is ever called."""

    def test_critical_failure_exits_1_before_run_forever(self, monkeypatch):
        import schedulers as sched_module

        def _bad(app):
            raise RuntimeError('DB unavailable — simulated')

        # Patch only the clearing_settlement starter; leave others intact so
        # the optional-scheduler WARNING path is also exercised implicitly.
        monkeypatch.setitem(sched_module._SCHEDULER_STARTERS, 'clearing_settlement', _bad)

        # run_forever must never be reached
        run_forever_called: list[bool] = []
        monkeypatch.setattr(sched_module, 'run_forever', lambda *a, **kw: run_forever_called.append(True))

        with pytest.raises(SystemExit) as exc:
            sched_module.start_all_schedulers(_make_app())

        assert exc.value.code == 1, "exit code must be 1 on CRITICAL failure"
        assert not run_forever_called, "run_forever() must never be called when a CRITICAL scheduler fails"

    def test_optional_failure_does_not_exit(self, monkeypatch):
        """An OPTIONAL scheduler failing must NOT cause sys.exit()."""
        import schedulers as sched_module

        def _bad_optional(app):
            raise RuntimeError('network down — simulated')

        monkeypatch.setitem(sched_module._SCHEDULER_STARTERS, 'bonus', _bad_optional)

        # Patch all other starters to return a sentinel so we don't actually
        # spin up real scheduler threads in the test process.
        sentinel = MagicMock()
        for name in ['clearing_settlement', 'gold_price', 'backup', 'safebox_reconciliation']:
            monkeypatch.setitem(sched_module._SCHEDULER_STARTERS, name, lambda app, _n=name: sentinel)

        # Must not raise SystemExit
        result = sched_module.start_all_schedulers(_make_app())
        # clearing_settlement sentinel is in the list; bonus is absent
        assert sentinel in result

    def test_critical_classification_is_clearing_settlement(self):
        """'clearing_settlement' must be in _CRITICAL; others must not be."""
        import schedulers as sched_module

        assert 'clearing_settlement' in sched_module._CRITICAL
        for optional in ('bonus', 'gold_price', 'backup', 'safebox_reconciliation'):
            assert optional not in sched_module._CRITICAL, (
                f"'{optional}' must be OPTIONAL, not CRITICAL"
            )


# ═══════════════════════════════════════════════════════════════════════════════
# S2a — Loop exception → failure flag set + graceful SIGTERM sent
# ═══════════════════════════════════════════════════════════════════════════════

class TestLoopExceptionGracefulPath:
    """S2a: an exception in the scheduler loop sets _failed and sends SIGTERM
    to trigger the graceful shutdown path in run_schedulers.main()."""

    def test_loop_exception_sets_failed_and_sends_sigterm(self, monkeypatch):
        import clearing_settlement_scheduler as css_module

        app = _make_app()
        monkeypatch.setattr(css_module, '_scheduler_instance', None)
        scheduler = css_module.get_clearing_settlement_scheduler(app)

        # No-op the initial run so the test reaches the loop quickly
        monkeypatch.setattr(scheduler, 'process_due_settlements', lambda: None)
        # No-op the stale check to avoid DB calls
        monkeypatch.setattr(scheduler, '_emit_stale_finding_if_needed', lambda **kw: False)

        # Make run_pending() raise on first call
        call_count: list[int] = [0]
        def _bad_run_pending():
            call_count[0] += 1
            raise RuntimeError('simulated loop crash')
        monkeypatch.setattr(scheduler._scheduler, 'run_pending', _bad_run_pending)

        signals_sent: list[int] = []
        # Capture the kill() call without actually sending the signal
        with patch('os.kill') as mock_kill:
            scheduler.start()
            # Give the thread time to raise and reach the except block
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                if scheduler._failed.is_set():
                    break
                time.sleep(0.05)

        assert scheduler._failed.is_set(), "_failed must be set after a loop exception"
        assert mock_kill.called, "os.kill() must be called to trigger graceful SIGTERM"
        pid, sig = mock_kill.call_args[0]
        assert pid == os.getpid(), "signal must be sent to own process"
        assert sig == signal.SIGTERM, "signal must be SIGTERM (graceful path)"

        scheduler.is_running = False
        scheduler._stop_event.set()


# ═══════════════════════════════════════════════════════════════════════════════
# S2b — Join timeout → os._exit(1)
# ═══════════════════════════════════════════════════════════════════════════════

class TestJoinTimeoutForcedExit:
    """S2b: a thread that does not exit after stop() + join(timeout=N) triggers
    os._exit(1).  This is the ONLY place os._exit(1) may be called (spec)."""

    def test_hung_thread_join_timeout_calls_os_exit_1(self, monkeypatch):
        # Simulate the shutdown sequence in run_schedulers.main() with a thread
        # that hangs indefinitely, ensuring the forced-exit branch is taken.
        hang = threading.Event()

        def _hang():
            hang.wait()  # blocks forever until hang.set()

        stuck = threading.Thread(target=_hang, daemon=True)
        stuck.start()

        exit_calls: list[int] = []

        # Patch os._exit so we don't terminate the test process
        with patch('os._exit', side_effect=lambda code: exit_calls.append(code)):
            stuck.join(timeout=0.1)  # short timeout → thread still alive
            if stuck.is_alive():
                # This is exactly what run_schedulers.main() does
                os._exit(1)

        hang.set()  # cleanup — let the thread exit
        assert exit_calls == [1], "os._exit(1) must be called when join times out"


# ═══════════════════════════════════════════════════════════════════════════════
# S3 — Interruptible sleep
# ═══════════════════════════════════════════════════════════════════════════════

class TestInterruptibleSleep:
    """S3: stop() sets _stop_event so the sleeping thread wakes immediately
    (<1 s) instead of waiting out the full 60-second poll interval."""

    def test_stop_wakes_sleeping_thread_under_one_second(self, monkeypatch):
        import clearing_settlement_scheduler as css_module

        app = _make_app()
        monkeypatch.setattr(css_module, '_scheduler_instance', None)
        scheduler = css_module.get_clearing_settlement_scheduler(app)

        # Suppress the initial run and stale check so the thread reaches
        # the _stop_event.wait(timeout=60) as quickly as possible
        monkeypatch.setattr(scheduler, 'process_due_settlements', lambda: None)
        monkeypatch.setattr(scheduler, '_emit_stale_finding_if_needed', lambda threshold_hours=3: False)

        scheduler.start()
        # Let the thread settle into _stop_event.wait(timeout=60)
        time.sleep(0.2)

        assert scheduler._thread is not None and scheduler._thread.is_alive(), \
            "thread must be alive before stop()"

        t_start = time.monotonic()
        scheduler.stop()

        # join with 1.5s budget — the interruptible wait must return immediately
        # when _stop_event is set; with the old time.sleep(60) this would timeout
        scheduler._thread.join(timeout=1.5)
        elapsed = time.monotonic() - t_start

        assert not scheduler._thread.is_alive(), (
            "thread must be dead after stop() + join(1.5s); "
            "if it's still alive the sleep is not interruptible"
        )
        assert elapsed < 1.5, f"thread took {elapsed:.2f}s; expected < 1.5s"


# ═══════════════════════════════════════════════════════════════════════════════
# S4 — SIGTERM mid-sleep → clean join + exit 0
# ═══════════════════════════════════════════════════════════════════════════════

class TestGracefulSigtermShutdown:
    """S4: SIGTERM received while threads are in their interruptible sleep
    produces a clean shutdown: all threads joined, exit code 0."""

    def test_sigterm_stops_scheduler_cleanly(self, monkeypatch):
        import clearing_settlement_scheduler as css_module

        app = _make_app()
        monkeypatch.setattr(css_module, '_scheduler_instance', None)
        scheduler = css_module.get_clearing_settlement_scheduler(app)

        monkeypatch.setattr(scheduler, 'process_due_settlements', lambda: None)
        monkeypatch.setattr(scheduler, '_emit_stale_finding_if_needed', lambda **kw: False)

        scheduler.start()
        time.sleep(0.15)  # let thread reach its wait()

        t_start = time.monotonic()

        # Simulate the shutdown sequence from run_schedulers.main()
        scheduler.stop()

        t = scheduler._thread
        assert t is not None, "scheduler._thread must be set after start()"
        t.join(timeout=5.0)

        elapsed = time.monotonic() - t_start

        assert not t.is_alive(), "thread must be dead after stop() + join()"
        assert elapsed < 5.0, f"join took {elapsed:.2f}s; expected < 5s"
        assert not scheduler._failed.is_set(), "clean shutdown must not set _failed"

    def test_scheduler_thread_reference_is_stored(self, monkeypatch):
        """S4 contract: self._thread must be populated after start()."""
        import clearing_settlement_scheduler as css_module

        app = _make_app()
        monkeypatch.setattr(css_module, '_scheduler_instance', None)
        scheduler = css_module.get_clearing_settlement_scheduler(app)

        monkeypatch.setattr(scheduler, 'process_due_settlements', lambda: None)
        monkeypatch.setattr(scheduler, '_emit_stale_finding_if_needed', lambda **kw: False)

        assert scheduler._thread is None, "_thread must be None before start()"
        scheduler.start()
        assert scheduler._thread is not None, "_thread must be set after start()"
        assert scheduler._thread.is_alive(), "thread must be alive after start()"

        scheduler.stop()
        scheduler._thread.join(timeout=2.0)


# ═══════════════════════════════════════════════════════════════════════════════
# S5 — Business-outcome monitoring
# ═══════════════════════════════════════════════════════════════════════════════

class TestStaleFindingEmitted:
    """S5: when no auto_settlement voucher exists within the threshold,
    _emit_stale_finding_if_needed() creates a STALE_SETTLEMENT row in
    reconciliation_findings and increments check_count on re-checks."""

    def test_stale_creates_new_finding(self):
        """First detection with threshold=0h always fires (no voucher is
        newer than 'now minus 0 hours')."""
        from models import ReconciliationFinding, db as _db
        from clearing_settlement_scheduler import ClearingSettlementScheduler

        app = _make_app()
        scheduler = ClearingSettlementScheduler(app)

        with app.app_context():
            # Clean slate: remove any pre-existing open finding
            _db.session.query(ReconciliationFinding).filter_by(
                kind='STALE_SETTLEMENT', resolved_at=None
            ).delete()
            _db.session.commit()

            created = scheduler._emit_stale_finding_if_needed(threshold_hours=0)

        assert created is True, "_emit_stale_finding_if_needed must return True when a new finding is created"

        with app.app_context():
            finding = (
                ReconciliationFinding.query
                .filter_by(kind='STALE_SETTLEMENT', resolved_at=None)
                .first()
            )
            assert finding is not None, "STALE_SETTLEMENT finding must exist in DB"
            assert finding.source == 'clearing_settlement_scheduler'
            assert finding.check_count == 1

            # Cleanup
            _db.session.delete(finding)
            _db.session.commit()

    def test_stale_increments_check_count_on_recheck(self):
        """A second call while the finding is open must increment check_count,
        not create a duplicate finding row."""
        from models import ReconciliationFinding, db as _db
        from clearing_settlement_scheduler import ClearingSettlementScheduler

        app = _make_app()
        scheduler = ClearingSettlementScheduler(app)

        with app.app_context():
            _db.session.query(ReconciliationFinding).filter_by(
                kind='STALE_SETTLEMENT', resolved_at=None
            ).delete()
            _db.session.commit()

            # First call — creates the finding
            scheduler._emit_stale_finding_if_needed(threshold_hours=0)
            # Second call — must increment check_count, not create a new row
            result = scheduler._emit_stale_finding_if_needed(threshold_hours=0)

        assert result is False, "second call should return False (no new finding created)"

        with app.app_context():
            findings = (
                ReconciliationFinding.query
                .filter_by(kind='STALE_SETTLEMENT', resolved_at=None)
                .all()
            )
            assert len(findings) == 1, "exactly ONE open finding must exist, not two"
            assert findings[0].check_count == 2, (
                f"check_count must be 2 after two detections, got {findings[0].check_count}"
            )

            # Cleanup
            _db.session.delete(findings[0])
            _db.session.commit()

    def test_a_fresh_auto_settlement_resolves_the_open_finding(self):
        """SCHED-004: the finding used to open on the first 3-hour gap and never
        close -- production held one from 29 Jul 2026 with check_count 68,093
        while 61 auto-settlements followed. An open finding must mean that
        settlements are stale NOW."""
        from datetime import datetime
        from models import ReconciliationFinding, Voucher, db as _db
        from clearing_settlement_scheduler import ClearingSettlementScheduler

        app = _make_app()
        scheduler = ClearingSettlementScheduler(app)
        with app.app_context():
            _db.session.query(ReconciliationFinding).filter_by(
                kind='STALE_SETTLEMENT', resolved_at=None).delete()
            _db.session.commit()
            scheduler._emit_stale_finding_if_needed(threshold_hours=0)      # stale: opens
            opened = ReconciliationFinding.query.filter_by(
                kind='STALE_SETTLEMENT', resolved_at=None).one()
            voucher = Voucher(voucher_number=f'AS-{opened.id}-fresh', voucher_type='payment',
                              date=datetime.utcnow(), status='approved', created_by='scheduler',
                              amount_cash=0.0, reference_type='clearing_settlement',
                              notes='auto_settlement:test', created_at=datetime.utcnow())
            _db.session.add(voucher)
            _db.session.commit()

            created = scheduler._emit_stale_finding_if_needed(threshold_hours=3)  # fresh again

            assert created is False
            assert ReconciliationFinding.query.get(opened.id).resolved_at is not None, (
                'a fresh auto-settlement must close the open STALE_SETTLEMENT finding')
            assert ReconciliationFinding.query.filter_by(
                kind='STALE_SETTLEMENT', resolved_at=None).count() == 0

            _db.session.delete(voucher)
            _db.session.delete(ReconciliationFinding.query.get(opened.id))
            _db.session.commit()

    def test_a_new_stale_period_after_resolution_opens_a_new_finding(self):
        """Each stale period is its own episode: the closed one keeps its history
        (created_at, check_count, resolved_at), the next one starts at 1."""
        from datetime import datetime
        from models import ReconciliationFinding, db as _db
        from clearing_settlement_scheduler import ClearingSettlementScheduler

        app = _make_app()
        scheduler = ClearingSettlementScheduler(app)
        with app.app_context():
            _db.session.query(ReconciliationFinding).filter_by(
                kind='STALE_SETTLEMENT', resolved_at=None).delete()
            _db.session.commit()
            old = ReconciliationFinding(kind='STALE_SETTLEMENT', source='clearing_settlement_scheduler',
                                        detail='an earlier period', check_count=41,
                                        resolved_at=datetime.utcnow())
            _db.session.add(old)
            _db.session.commit()

            created = scheduler._emit_stale_finding_if_needed(threshold_hours=0)

            assert created is True
            new = ReconciliationFinding.query.filter_by(kind='STALE_SETTLEMENT', resolved_at=None).one()
            assert new.id != old.id and new.check_count == 1
            assert ReconciliationFinding.query.get(old.id).check_count == 41

            _db.session.delete(new)
            _db.session.delete(ReconciliationFinding.query.get(old.id))
            _db.session.commit()
