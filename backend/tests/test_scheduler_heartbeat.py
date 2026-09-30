"""A scheduler that stops is seen in the app's bell (SCHED-004, RESTART-001).

The settlement alarm runs inside the scheduler container, so when that
container dies -- or keeps restarting -- nothing raised anything. Now the
scheduler writes a heartbeat to the database: the process each minute
('erp-scheduler') and the settlement loop on each wake ('clearing_settlement'),
the one whose death stops money moving. The backend -- a different process --
reads them: a heartbeat silent longer than SCHEDULER_HEARTBEAT_STALE_SECONDS
(policy, default 300) is a 'scheduler_down' entry in GET /api/pending-actions,
which feeds the home screen's bell -- the only bell the app has (the alerts
dialog and screen were removed on 2 Jun 2026, 448e475; the first version of
this wrote SystemAlert rows nobody could see). Computed on each read, so it is
gone the moment the scheduler beats again, and nothing can dismiss it before.

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
    yield
    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


NOW = datetime(2026, 9, 29, 12, 0, 0)


def _beat_all(at):
    for name in hb.EXPECTED:
        hb.beat(name, now=at)




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
    """GET /api/pending-actions -- what the home screen's bell reads, on a timer."""

    def _pending(self, app, auth_headers):
        with app.test_client() as c:
            resp = c.get('/api/pending-actions', headers=auth_headers)
        assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
        return resp.get_json()

    def test_a_silent_scheduler_is_in_the_bell(self, app, auth_headers):
        _beat_all(datetime.utcnow() - timedelta(minutes=30))
        data = self._pending(app, auth_headers)
        assert data['total_system_alerts'] == 1
        alert = data['system_alerts'][0]
        assert alert['kind'] == 'scheduler_down' and 'المجدول' in alert['title']
        assert {s['name'] for s in alert['silent']} == set(hb.EXPECTED)
        assert 'منذ 30 دقيقة' in alert['message']

    def test_a_beating_scheduler_is_not(self, app, auth_headers):
        _beat_all(datetime.utcnow())
        data = self._pending(app, auth_headers)
        assert data['total_system_alerts'] == 0 and data['system_alerts'] == []

    def test_reading_the_bell_writes_nothing(self, app, auth_headers):
        _beat_all(datetime.utcnow() - timedelta(minutes=30))
        before = SystemAlert.query.count()
        self._pending(app, auth_headers)
        assert SystemAlert.query.count() == before

    def test_nothing_writes_scheduler_alerts_any_more(self):
        """The dashboard and the old alerts route no longer refresh a SystemAlert."""
        from routes import reports, system
        assert 'refresh_bell' not in inspect.getsource(reports.get_admin_dashboard) \
            if hasattr(reports, 'get_admin_dashboard') else True
        assert 'refresh_bell' not in inspect.getsource(system.list_system_alerts)
        assert not hasattr(hb, 'sync_scheduler_alert') and not hasattr(hb, 'refresh_bell')


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


def test_the_settlement_loop_beats_before_its_first_run():
    """It first beat after its initial run and a 60-second wait: in that first
    minute after every deploy the bell said "scheduler down" (found 29 Sep 2026,
    release 77ca191a). It beats as soon as its thread starts."""
    from clearing_settlement_scheduler import ClearingSettlementScheduler
    src = inspect.getsource(ClearingSettlementScheduler.start)
    first_beat = src.index("beat('clearing_settlement')")
    assert first_beat < src.index('self.process_due_settlements()')
