"""Dedicated scheduler runner.

Use this in production as a separate process/container, so the web server
(gunicorn) can run multiple workers without duplicating scheduler jobs.

Shutdown sequence (S4):
  SIGTERM/SIGINT
    → run_forever() unblocks immediately (threading.Event)
    → stop() called on each scheduler (S3: wakes sleeping threads via _stop_event)
    → join(timeout=30) on each scheduler thread
    → if a thread is still alive after 30s → os._exit(1)  ← forced path (S2)
    → sys.exit(1) if any scheduler marked _failed, else sys.exit(0)

Example:
    python run_schedulers.py
"""

import os
import sys
import threading

# When run as `python backend/run_schedulers.py`, Python adds /app/backend to
# sys.path (the script directory), not /app.  Insert it explicitly so that
# sibling modules (app, schedulers, …) are importable without the `backend.` prefix.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app
from schedulers import start_all_schedulers, run_forever


def main():
    os.environ.setdefault('YASAR_ENV', os.getenv('YASAR_ENV', 'production'))

    # S1: CRITICAL schedulers that fail to start → sys.exit(1) inside
    # start_all_schedulers(); run_forever() is never reached.
    schedulers = start_all_schedulers(app)
    print('[INFO] Schedulers are running')

    # S2: pass CRITICAL schedulers (those with a _failed event) so
    # run_forever() can detect unexpected thread death via liveness polling.
    critical = [s for s in schedulers if hasattr(s, '_failed')]

    def _heartbeat():
        from models import db
        from services.scheduler_heartbeat import beat
        with app.app_context():
            try:
                beat('erp-scheduler')
            except Exception:
                db.session.rollback()
                raise

    _heartbeat()
    run_forever(critical_schedulers=critical, on_tick=_heartbeat)

    # ── Graceful shutdown sequence (S4) ──────────────────────────────────────
    # run_forever() has returned (SIGTERM or SIGINT received, or liveness
    # check triggered graceful exit).  Stop all schedulers so their loops
    # exit cleanly, then join their threads before we check exit code.

    for s in schedulers:
        if hasattr(s, 'stop'):
            s.stop()

    for s in schedulers:
        t = getattr(s, '_thread', None)
        if t is not None and t.is_alive():
            t.join(timeout=30)
            if t.is_alive():
                # Thread did not respond to stop() within 30s — forced exit.
                # This is the ONLY place os._exit(1) is called (S2 spec).
                print('[erp-scheduler] ☠ join timed out — forcing exit', flush=True)
                os._exit(1)

    # Exit 1 if any CRITICAL scheduler flagged a failure, 0 on clean shutdown
    failed = any(
        getattr(s, '_failed', threading.Event()).is_set()
        for s in schedulers
    )
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
