"""The scheduler's heartbeat, and the bell that shows its silence.

The settlement alarm runs inside the scheduler container, so the container's
own death raised nothing (SCHED-004). The scheduler writes a heartbeat; the
backend -- a different process -- reads it in GET /api/pending-actions, which
the home screen's bell polls: a silent heartbeat is a 'scheduler_down' entry
there (the owner's choice, 29 Sep 2026: the bell). The app has no other bell:
the alerts dialog and screen were removed on 2 Jun 2026 (448e475), and the
first version of this, which wrote SystemAlert rows, was never seen.

LAW: a silent scheduler is in the bell, computed on every read -- nothing can
dismiss it while it is silent, and it is gone the moment the scheduler beats.
POLICY: how long silence may last, SCHEDULER_HEARTBEAT_STALE_SECONDS (300).
"""
from __future__ import annotations

import os
import socket
from datetime import datetime
from typing import Optional

from models import SchedulerHeartbeat, db

# 'erp-scheduler': the process, each minute (schedulers.run_forever).
# 'clearing_settlement': the settlement loop, each wake -- the one whose death
# stops money moving.
EXPECTED = ('erp-scheduler', 'clearing_settlement')
KIND = 'scheduler_down'
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


def system_alerts(now: Optional[datetime] = None) -> list:
    """What the bell shows about the system itself. Read-only."""
    silent = silent_schedulers(now)
    if not silent:
        return []
    return [{
        'kind': KIND,
        'title': 'المجدول متوقف',
        'message': _message(silent),
        'what_to_do': 'على الخادم: docker ps -a ثم docker logs yasargold-scheduler --tail 50',
        'silent': silent,
    }]
