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

Nothing here writes.
"""
from __future__ import annotations

from datetime import datetime, timedelta

NIGHTLY_LATE = timedelta(hours=26)


def _iso(when: datetime | None) -> str | None:
    return None if when is None else when.isoformat() + 'Z'


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
    }
