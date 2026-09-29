"""ERP background-scheduler orchestrator.

Process model
─────────────
This module is the ONLY entry-point for the erp-scheduler Docker service
(run_schedulers.py → main() → start_all_schedulers() → run_forever()).
It must NEVER be imported by wsgi.py or any Gunicorn worker.

Scheduler classification
────────────────────────
CRITICAL  — absence means money stops moving.  Startup failure → sys.exit(1)
            before run_forever() so the process refuses to boot headless.
            Currently: clearing_settlement.

OPTIONAL  — degraded but tolerable.  Startup failure → WARNING, process continues.
            Currently: bonus, gold_price, backup, safebox_reconciliation,
            books_invariants (report-only: it must never be why money stops).
"""

from __future__ import annotations

import os as _os
import signal as _signal
import sys as _sys
import threading as _threading

# ── Classification ────────────────────────────────────────────────────────────

_CRITICAL: frozenset[str] = frozenset({'clearing_settlement'})

# ── Named starter functions (module-level so tests can monkeypatch via
#    _SCHEDULER_STARTERS without patching deep import chains) ─────────────────

def _start_clearing_settlement(app):
    from clearing_settlement_scheduler import start_clearing_settlement_scheduler
    return start_clearing_settlement_scheduler(app)


def _start_bonus(app):
    from bonus_scheduler import start_bonus_scheduler
    return start_bonus_scheduler(app)


def _start_gold_price(app):
    from gold_price_scheduler import start_gold_price_scheduler
    return start_gold_price_scheduler(app)


def _start_backup(app):
    from backup_scheduler import start_backup_scheduler
    return start_backup_scheduler(app)


def _start_safebox_reconciliation(app):
    from safebox_reconciliation_scheduler import start_safebox_reconciliation_scheduler
    return start_safebox_reconciliation_scheduler(app)


def _start_books_invariants(app):
    from books_invariants_scheduler import start_books_invariants_scheduler
    return start_books_invariants_scheduler(app)


def _start_gold_acquisition_reconciliation(app):
    from gold_acquisition_reconciliation_scheduler import start_gold_acquisition_reconciliation_scheduler
    return start_gold_acquisition_reconciliation_scheduler(app)


_SCHEDULER_STARTERS: dict[str, object] = {
    'clearing_settlement':              _start_clearing_settlement,
    'bonus':                            _start_bonus,
    'gold_price':                       _start_gold_price,
    'backup':                           _start_backup,
    'safebox_reconciliation':           _start_safebox_reconciliation,
    'books_invariants':                 _start_books_invariants,
    'gold_acquisition_reconciliation':  _start_gold_acquisition_reconciliation,
}

# ── Public API ────────────────────────────────────────────────────────────────

def start_all_schedulers(app) -> list:
    """Start all background schedulers and return a list of started instances.

    CRITICAL schedulers: failure → sys.exit(1) immediately.  run_forever() is
    never reached, which is the desired fail-closed behaviour (Law 7 applied
    to ERP: a financial background process must refuse to run headless).

    OPTIONAL schedulers: failure → WARNING log, process continues.
    """
    started: list = []
    for name, starter in _SCHEDULER_STARTERS.items():
        try:
            result = starter(app)
            if result is not None:
                started.append(result)
        except Exception as exc:
            if name in _CRITICAL:
                print(
                    f'[erp-scheduler] FATAL: Critical scheduler "{name}" failed to start: {exc}',
                    flush=True,
                )
                _sys.exit(1)
            else:
                print(f'[WARNING] Optional scheduler "{name}" not started: {exc}')
    return started


def run_forever(critical_schedulers: list = (), poll_seconds: float = 60.0) -> None:
    """Block until SIGTERM or SIGINT, polling critical-scheduler liveness every
    poll_seconds seconds.

    Liveness rule (S2): if a CRITICAL scheduler's thread is not alive AND its
    stop_event was not set (i.e. stop() was never called), the thread died
    unexpectedly.  We mark it failed and trigger a graceful shutdown so
    main() can exit with code 1 and Docker's restart policy kicks in.

    The forced os._exit(1) path is NOT here — it lives in run_schedulers.py
    inside the join sequence (S4), and only fires when a thread is truly hung
    after stop() was called.
    """
    stop = _threading.Event()

    def _on_signal(signum: int, _frame: object) -> None:
        print(f'[erp-scheduler] signal {signum} received — stopping', flush=True)
        stop.set()

    _signal.signal(_signal.SIGTERM, _on_signal)
    _signal.signal(_signal.SIGINT, _on_signal)

    print('[erp-scheduler] running; send SIGTERM or SIGINT to stop', flush=True)

    while not stop.wait(timeout=poll_seconds):
        # Liveness check for every CRITICAL scheduler thread
        for s in critical_schedulers:
            t = getattr(s, '_thread', None)
            stop_ev = getattr(s, '_stop_event', None)
            if t is not None and not t.is_alive():
                if stop_ev is None or not stop_ev.is_set():
                    # Thread died without a normal stop() — unexpected death
                    print(
                        '[erp-scheduler] ☠ critical scheduler thread died unexpectedly'
                        ' — triggering graceful shutdown',
                        flush=True,
                    )
                    failed_ev = getattr(s, '_failed', None)
                    if failed_ev is not None and not failed_ev.is_set():
                        failed_ev.set()
                    stop.set()
                    break

    print('[erp-scheduler] stopped', flush=True)
