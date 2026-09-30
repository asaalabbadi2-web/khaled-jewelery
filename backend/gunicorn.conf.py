"""gunicorn settings for production (backend/Dockerfile runs it with -c).

The settings are the ones the command line carried until 30 Sep 2026.
"""
import faulthandler

bind = '0.0.0.0:8001'
workers = 2
timeout = 120


def post_worker_init(worker):
    """A worker killed for hanging writes every thread's stack first (HANG-001).

    On timeout gunicorn sends SIGABRT, then SIGKILL. Its SIGABRT handler is
    Python, and a worker blocked inside C -- libpq waiting on a lock -- never
    runs it: the log said «WORKER TIMEOUT» and nothing more (invoice 3170, 30 Sep
    2026). faulthandler's handler is C and runs at once. Registered here, after
    gunicorn installs its own handlers: after writing, faulthandler hands the
    signal back to gunicorn's. (SIGABRT is one of its fatal signals, so enable(),
    not register(); a worker that crashes outright leaves its stack too.)"""
    faulthandler.enable(all_threads=True)
