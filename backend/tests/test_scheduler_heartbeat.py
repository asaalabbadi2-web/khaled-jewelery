"""A scheduler that stops is seen in the app's alert bell (SCHED-004, RESTART-001).

The settlement alarm runs inside the scheduler container, so when that
container dies -- or keeps restarting -- nothing raised anything. Now the
scheduler writes a heartbeat to the database: the process each minute
('erp-scheduler') and the settlement loop on each wake ('clearing_settlement'),
the one whose death stops money moving. The backend -- a different process --
reads them: a heartbeat silent longer than SCHEDULER_HEARTBEAT_STALE_SECONDS
(policy, default 300) keeps ONE critical 'scheduler_down' alert open in the
bell (the owner's choice, 29 Sep 2026), and closes it on its own once every
heartbeat is fresh. Marking it reviewed while the scheduler is still silent
does not silence it: the next read opens it again.

Run:
    python -m pytest tests/test_scheduler_heartbeat.py -v
"""
import inspect
import json
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import SchedulerHeartbeat, SystemAlert, db
from services import scheduler_heartbeat as hb


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, monkeypatch):
    # TEST-001: this fence does not isolate a commit, so commits become flushes.
    monkeypatch.setattr(db.session, 'commit', db.session.flush)
    connection = db.engine.connect()
    transaction = connection.begin()
    db.session.bind = connection
    nested = connection.begin_nested()
    SchedulerHeartbeat.query.delete()
    SystemAlert.query.filter_by(alert_type=hb.ALERT_TYPE).delete()
    yield
    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


NOW = datetime(2026, 9, 29, 12, 0, 0)


def _beat_all(at):
    for name in hb.EXPECTED:
        hb.beat(name, now=at)


def _open_alerts():
    return SystemAlert.query.filter_by(alert_type=hb.ALERT_TYPE, is_reviewed=False).all()


class TestTheHeartbeat:
    def test_a_beat_is_one_row_per_scheduler_moved_forward(self):
        hb.beat('erp-scheduler', now=NOW)
        hb.beat('erp-scheduler', now=NOW + timedelta(minutes=1))
        rows = SchedulerHeartbeat.query.filter_by(name='erp-scheduler').all()
        assert len(rows) == 1 and rows[0].beat_at == NOW + timedelta(minutes=1)

    def test_fresh_beats_are_not_silent(self):
        _beat_all(NOW - timedelta(minutes=2))
        assert hb.silent_schedulers(NOW) == []

    def test_a_beat_older_than_the_limit_is_silent(self):
        _beat_all(NOW - timedelta(minutes=2))
        hb.beat('clearing_settlement', now=NOW - timedelta(minutes=9))
        silent = hb.silent_schedulers(NOW)
        assert [s['name'] for s in silent] == ['clearing_settlement']
        assert silent[0]['silent_minutes'] == 9

    def test_a_scheduler_never_heard_from_is_silent(self):
        hb.beat('erp-scheduler', now=NOW)
        assert [s['name'] for s in hb.silent_schedulers(NOW)] == ['clearing_settlement']

    def test_the_limit_is_policy_with_a_default_of_five_minutes(self, monkeypatch):
        monkeypatch.delenv('SCHEDULER_HEARTBEAT_STALE_SECONDS', raising=False)
        assert hb.stale_seconds() == 300
        monkeypatch.setenv('SCHEDULER_HEARTBEAT_STALE_SECONDS', '600')
        assert hb.stale_seconds() == 600
        monkeypatch.setenv('SCHEDULER_HEARTBEAT_STALE_SECONDS', 'x')
        assert hb.stale_seconds() == 300


class TestTheBell:
    def test_silence_opens_one_critical_alert_and_keeps_it_one(self):
        hb.beat('erp-scheduler', now=NOW - timedelta(minutes=20))
        hb.beat('clearing_settlement', now=NOW - timedelta(minutes=20))
        hb.sync_scheduler_alert(NOW)
        hb.sync_scheduler_alert(NOW + timedelta(minutes=1))
        alerts = _open_alerts()
        assert len(alerts) == 1
        alert = alerts[0]
        assert alert.severity == 'critical'
        assert 'المجدول' in alert.title
        details = json.loads(alert.details)
        assert {s['name'] for s in details['silent']} == {'erp-scheduler', 'clearing_settlement'}
        assert details['silent'][0]['silent_minutes'] == 21, 'the message follows the silence'

    def test_it_closes_on_its_own_once_every_beat_is_fresh(self):
        hb.beat('erp-scheduler', now=NOW - timedelta(minutes=20))
        hb.beat('clearing_settlement', now=NOW - timedelta(minutes=20))
        hb.sync_scheduler_alert(NOW)
        _beat_all(NOW + timedelta(minutes=1))
        hb.sync_scheduler_alert(NOW + timedelta(minutes=2))
        assert _open_alerts() == []
        closed = SystemAlert.query.filter_by(alert_type=hb.ALERT_TYPE).one()
        assert closed.is_reviewed and closed.reviewed_by == 'system'

    def test_marking_it_reviewed_does_not_silence_a_scheduler_still_down(self):
        hb.beat('erp-scheduler', now=NOW - timedelta(minutes=20))
        hb.sync_scheduler_alert(NOW)
        _open_alerts()[0].is_reviewed = True
        db.session.flush()
        hb.sync_scheduler_alert(NOW + timedelta(minutes=1))
        assert len(_open_alerts()) == 1

    def test_nothing_is_opened_while_everything_beats(self):
        _beat_all(NOW)
        hb.sync_scheduler_alert(NOW + timedelta(seconds=30))
        assert SystemAlert.query.filter_by(alert_type=hb.ALERT_TYPE).count() == 0


class TestThroughTheRoutes:
    def test_the_dashboard_counts_it_and_the_bell_lists_it(self, app, auth_headers):
        silent_since = datetime.utcnow() - timedelta(minutes=30)
        _beat_all(silent_since)
        with app.test_client() as c:
            dash = c.get('/api/dashboard/admin', headers=auth_headers).get_json()
            bell = c.get('/api/system-alerts?severity=critical&reviewed=false', headers=auth_headers).get_json()
        assert dash['alerts']['critical_unreviewed_count'] >= 1
        assert any((a or {}).get('alert_type') == hb.ALERT_TYPE for a in [dash['alerts']['critical_unreviewed_latest']])
        assert any(a['alert_type'] == hb.ALERT_TYPE for a in bell['alerts'])


class TestTheWriters:
    def test_the_scheduler_process_beats_on_every_poll(self):
        import schedulers
        src = inspect.getsource(schedulers.run_forever)
        assert 'on_tick' in src
        import run_schedulers
        assert "beat('erp-scheduler')" in inspect.getsource(run_schedulers)

    def test_run_forever_calls_on_tick_each_poll(self, monkeypatch):
        import schedulers
        ticks = []

        def tick():
            ticks.append(1)
            if len(ticks) >= 3:
                import signal, os
                os.kill(os.getpid(), signal.SIGTERM)

        schedulers.run_forever(critical_schedulers=[], poll_seconds=0.01, on_tick=tick)
        assert len(ticks) >= 3

    def test_the_settlement_loop_beats_on_every_wake(self):
        from clearing_settlement_scheduler import ClearingSettlementScheduler
        src = inspect.getsource(ClearingSettlementScheduler.start)
        assert "beat('clearing_settlement')" in src
