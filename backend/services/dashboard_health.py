"""Is the system doing its own work -- for the manager's dashboard (the owner, 15 Nov 2026).

«اقترح ما ينقصها»: the dashboard said nothing of whether the jobs that keep
the books honest were running. Three facts, each from what writes it:

  scheduler  the scheduler process's heartbeat (services/scheduler_heartbeat,
             SCHED-004): alive within its limit, or silent since when
  nightly    when the books' nightly check last ran whole (its heartbeat,
             written after its commit -- books_invariants_scheduler); late
             past a day and two hours
  backup     the newest backup the server keeps (backup_scheduler's folder),
             and whether automatic backups are on. A backup made elsewhere
             -- the host's copy to the drive -- is not the server's to see,
             and is not said.
  certificate  the shop name's HTTPS certificate (ADR-098), from the status
             file its tool writes (TLS_STATUS_FILE): its expiry, its last
             renewal; a warning when the last attempt failed, under 20 days
             left, the tool silent past 26 hours, no status written, or a
             staging certificate. Not configured: not said.

Nothing here writes.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta

NIGHTLY_LATE = timedelta(hours=26)
CERT_WARN_DAYS = 20
CERT_SILENT = timedelta(hours=26)      # the tool attempts every 12 hours


def _iso(when: datetime | None) -> str | None:
    return None if when is None else when.isoformat() + 'Z'


def _when(text):
    try:
        return datetime.fromisoformat(str(text).rstrip('Z'))
    except (TypeError, ValueError):
        return None


def certificate(now_utc: datetime) -> dict | None:
    """The shop name's certificate as its tool last said it (ADR-098 §5)."""
    path = os.environ.get('TLS_STATUS_FILE')
    if not path:
        return None
    try:
        with open(path) as f:
            status = json.load(f)
    except (OSError, ValueError):
        return {'state': 'alert', 'reasons': ['missing'], 'host': None, 'expires_at': None, 'days_left': None,
                'last_renewed_at': None, 'attempt_at': None, 'result': None, 'error': None}
    if status.get('result') == 'disabled':
        return {'state': 'disabled', 'reasons': []}
    expires, attempted = _when(status.get('expires_at')), _when(status.get('attempt_at'))
    days_left = None if expires is None else (expires - now_utc).days
    reasons = []
    if status.get('result') == 'failed':
        reasons.append('failed')
    if days_left is not None and days_left < CERT_WARN_DAYS:
        reasons.append('expiring')
    if attempted is None or now_utc - attempted > CERT_SILENT:
        reasons.append('stale')
    if status.get('staging'):
        reasons.append('staging')
    return {'state': 'alert' if reasons else 'ok', 'reasons': reasons, 'host': status.get('host'),
            'expires_at': status.get('expires_at'), 'days_left': days_left,
            'last_renewed_at': status.get('last_renewed_at'), 'attempt_at': status.get('attempt_at'),
            'result': status.get('result'), 'error': status.get('error')}


def health(now_utc: datetime, *, backup_dir=None) -> dict:
    from books_invariants_scheduler import NIGHTLY
    from models import SchedulerHeartbeat, Settings
    from services.scheduler_heartbeat import stale_seconds

    beats = {r.name: r.beat_at for r in SchedulerHeartbeat.query.all()}
    process = beats.get('erp-scheduler')
    silent = None if process is None else int((now_utc - process).total_seconds() // 60)
    nightly = beats.get(NIGHTLY)

    if backup_dir is None:
        from flask import current_app
        from backup_scheduler import get_backup_scheduler
        backup_dir = get_backup_scheduler(current_app._get_current_object())._backup_dir()
    files = sorted(backup_dir.glob('yasargold-backup-*.zip'), key=lambda p: p.stat().st_mtime) \
        if backup_dir.exists() else []
    newest = datetime.utcfromtimestamp(files[-1].stat().st_mtime) if files else None
    settings = Settings.query.first()

    return {
        'scheduler': {'last': _iso(process), 'alive': process is not None and silent * 60 <= stale_seconds(),
                      'silent_minutes': silent},
        'nightly': {'last': _iso(nightly), 'late': nightly is None or now_utc - nightly > NIGHTLY_LATE},
        'backup': {'last': _iso(newest), 'auto': bool(getattr(settings, 'backup_auto_enabled', False))},
        'certificate': certificate(now_utc),
    }
