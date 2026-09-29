"""The scheduler's heartbeat, and the alert bell it keeps honest.

The settlement alarm runs inside the scheduler container, so the container's
own death raised nothing (SCHED-004). The scheduler writes a heartbeat; the
backend -- a different process -- reads it whenever the admin dashboard or the
alert bell is loaded, and keeps ONE critical 'scheduler_down' SystemAlert open
while any expected heartbeat is silent, closing it itself once all are fresh
(the owner's choice, 29 Sep 2026: the bell).

LAW: a silent scheduler is visible in the bell and cannot be dismissed while
it is still silent -- a reviewed alert is reopened on the next read.
POLICY: how long silence may last, SCHEDULER_HEARTBEAT_STALE_SECONDS (300).
"""
from __future__ import annotations

import json
import os
import socket
from datetime import datetime
from typing import Optional

from models import SchedulerHeartbeat, SystemAlert, db

# 'erp-scheduler': the process, each minute (schedulers.run_forever).
# 'clearing_settlement': the settlement loop, each wake -- the one whose death
# stops money moving.
EXPECTED = ('erp-scheduler', 'clearing_settlement')
ALERT_TYPE = 'scheduler_down'
_DEFAULT_STALE_SECONDS = 300


def stale_seconds() -> int:
    try:
        return max(int(os.getenv('SCHEDULER_HEARTBEAT_STALE_SECONDS', _DEFAULT_STALE_SECONDS)), 60)
    except ValueError:
        return _DEFAULT_STALE_SECONDS


def beat(name: str, now: Optional[datetime] = None) -> None:
    """Record that *name* is alive. Commits: it runs in the scheduler, alone."""
    now = now or datetime.utcnow()
    row = SchedulerHeartbeat.query.get(name)
    if row is None:
        row = SchedulerHeartbeat(name=name)
        db.session.add(row)
    row.beat_at = now
    row.pid = os.getpid()
    row.host = socket.gethostname()[:100]
    db.session.commit()


def silent_schedulers(now: Optional[datetime] = None) -> list:
    """Every expected heartbeat older than the limit, or never written."""
    now = now or datetime.utcnow()
    limit = stale_seconds()
    rows = {r.name: r for r in SchedulerHeartbeat.query.filter(SchedulerHeartbeat.name.in_(EXPECTED)).all()}
    silent = []
    for name in EXPECTED:
        row = rows.get(name)
        if row is None:
            silent.append({'name': name, 'last_beat_at': None, 'silent_minutes': None})
            continue
        age = (now - row.beat_at).total_seconds()
        if age > limit:
            silent.append({'name': name, 'last_beat_at': row.beat_at.isoformat() + 'Z',
                           'silent_minutes': int(age // 60)})
    return silent


def _message(silent: list) -> str:
    parts = []
    for s in silent:
        label = 'التسويات' if s['name'] == 'clearing_settlement' else 'المجدول'
        parts.append(f"{label}: لا نبض منذ {s['silent_minutes']} دقيقة" if s['silent_minutes'] is not None
                     else f"{label}: لم يُسمع نبضه قط")
    return ' · '.join(parts) + ' — التسويات التلقائية والنسخ الاحتياطي والفحوص الليلية لا تعمل.'


def sync_scheduler_alert(now: Optional[datetime] = None) -> Optional[SystemAlert]:
    """Open, refresh or close the one scheduler_down alert. Caller commits."""
    now = now or datetime.utcnow()
    silent = silent_schedulers(now)
    open_alert = (SystemAlert.query
                  .filter_by(alert_type=ALERT_TYPE, is_reviewed=False)
                  .order_by(SystemAlert.id.desc()).first())
    if not silent:
        if open_alert is not None:
            open_alert.is_reviewed = True
            open_alert.reviewed_by = 'system'
            open_alert.reviewed_at = now
            db.session.flush()
        return None
    details = json.dumps({'silent': silent, 'checked_at': now.isoformat() + 'Z',
                          'limit_seconds': stale_seconds()}, ensure_ascii=False)
    if open_alert is None:
        open_alert = SystemAlert(alert_type=ALERT_TYPE, severity='critical',
                                 title='المجدول متوقف', entity_type='Scheduler',
                                 created_by='system', created_at=now)
        db.session.add(open_alert)
    open_alert.message = _message(silent)
    open_alert.details = details
    db.session.flush()
    return open_alert


def refresh_bell() -> None:
    """For the read paths (dashboard, bell): never let the check break them."""
    try:
        sync_scheduler_alert()
        db.session.commit()
    except Exception as exc:  # the dashboard must load even if this fails
        db.session.rollback()
        print(f'[scheduler_heartbeat] bell refresh failed: {exc}', flush=True)
