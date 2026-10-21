"""«تشغيل التسوية الآلية الآن»: the route runs the scheduler once and says what it did.

Brought in from the root (TEST-003): its fake scheduler returned nothing, and
since process_due_settlements() returns its summary the route reads it -- a
500 on the fake, unseen. The fake returns a summary, as the scheduler does.
"""
import pytest

import clearing_settlement_scheduler
from app import app


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def test_running_the_auto_settlement_now_runs_the_scheduler_once(auth_headers, monkeypatch):
    called = {'count': 0}

    class _FakeScheduler:
        def process_due_settlements(self):
            called['count'] += 1
            return {'settled_count': 0, 'enabled_methods': 2, 'skipped': []}

    monkeypatch.setattr(clearing_settlement_scheduler, 'get_clearing_settlement_scheduler',
                        lambda app_obj: _FakeScheduler())

    response = app.test_client().post('/api/clearing/settlements/auto-run', json={}, headers=auth_headers)
    assert response.status_code == 200, response.get_data(as_text=True)[:300]
    payload = response.get_json()
    assert payload['success'] is True
    assert (payload['enabled_methods'], payload['settled_count']) == (2, 0)
    assert called['count'] == 1
