"""The dashboard says whether the system is doing its own work (the owner, 15 Nov 2026).

The laws:
  - the scheduler alive within its heartbeat's limit, or silent since when;
  - the nightly check's last whole run -- written by the run itself, after its
    commit -- late past 26 hours, or never;
  - the server's newest backup, and whether automatic backups are on.

Run:
    python -m pytest tests/test_dashboard_says_the_system_s_health.py -v
"""
import os
import time
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import SchedulerHeartbeat, db
from services.dashboard_health import health

NOW = datetime(2026, 11, 15, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    SchedulerHeartbeat.query.delete()
    db.session.flush()
    yield


def _beat(name, at):
    db.session.add(SchedulerHeartbeat(name=name, beat_at=at))
    db.session.flush()


def test_alive_silent_and_never(tmp_path):
    assert health(NOW, backup_dir=tmp_path)['scheduler'] == {'last': None, 'alive': False, 'silent_minutes': None}
    _beat('erp-scheduler', NOW - timedelta(minutes=1))
    assert health(NOW, backup_dir=tmp_path)['scheduler']['alive'] is True
    SchedulerHeartbeat.query.filter_by(name='erp-scheduler').one().beat_at = NOW - timedelta(minutes=40)
    db.session.flush()
    said = health(NOW, backup_dir=tmp_path)['scheduler']
    assert (said['alive'], said['silent_minutes']) == (False, 40)


def test_the_nightly_check_says_when_it_last_ran_and_late_past_a_day(tmp_path):
    from books_invariants_scheduler import NIGHTLY
    assert health(NOW, backup_dir=tmp_path)['nightly'] == {'last': None, 'late': True}
    _beat(NIGHTLY, NOW - timedelta(hours=9))
    assert health(NOW, backup_dir=tmp_path)['nightly']['late'] is False
    SchedulerHeartbeat.query.filter_by(name=NIGHTLY).one().beat_at = NOW - timedelta(hours=30)
    db.session.flush()
    assert health(NOW, backup_dir=tmp_path)['nightly']['late'] is True


def test_a_whole_run_of_the_nightly_check_writes_its_heartbeat(app, monkeypatch):
    import books_invariants_scheduler as nightly
    import services.books_invariants as invariants
    monkeypatch.setattr(invariants, 'run_books_invariants', lambda now=None: {})
    beats = []
    import services.scheduler_heartbeat as heartbeat
    monkeypatch.setattr(heartbeat, 'beat', lambda name, now=None: beats.append(name))
    nightly.BooksInvariantsScheduler(app).run_once()
    assert beats == [nightly.NIGHTLY]


def test_the_newest_backup_the_server_keeps(tmp_path):
    assert health(NOW, backup_dir=tmp_path)['backup']['last'] is None
    for name, age in (('yasargold-backup-a.zip', 7200), ('yasargold-backup-b.zip', 60)):
        f = tmp_path / name
        f.write_bytes(b'x')
        t = time.time() - age
        os.utime(f, (t, t))
    (tmp_path / 'other.zip').write_bytes(b'x')
    last = datetime.fromisoformat(health(NOW, backup_dir=tmp_path)['backup']['last'].rstrip('Z'))
    assert abs((datetime.utcnow() - last).total_seconds() - 60) < 5
