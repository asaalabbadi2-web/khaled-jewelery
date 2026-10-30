"""Where the business stands is its own request, beside the dashboard (DASH-10).

The owner, 30 Oct 2026: «الشاشة أصبحت تأخذ وقتًا طويلًا في التحميل». The six
readers DASH-4..9 added were summed onto the dashboard's one request and the
screen waited for all of it; now they are /dashboard/admin/standing, asked
beside it. The manager's alone, as the dashboard; a section that fails is
null and the others stand.

Run:
    python -m pytest tests/test_dashboard_standing_is_its_own_request.py -v
"""
import uuid

import pytest

from models import db

SECTIONS = {'positions', 'clearing', 'approvals', 'wrong_now', 'vat', 'deficits'}


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_the_six_are_their_own_request(app, auth_headers):
    client = app.test_client()
    standing = client.get('/api/dashboard/admin/standing', headers=auth_headers).get_json()
    assert SECTIONS <= set(standing) and all(standing[k] is not None for k in SECTIONS)
    dashboard = client.get('/api/dashboard/admin', headers=auth_headers).get_json()
    assert not SECTIONS & set(dashboard), 'the dashboard no longer waits for them'


def test_a_section_that_fails_is_null_and_the_rest_stand(app, auth_headers, monkeypatch):
    import services.dashboard_vat as vat

    def broken(today):
        raise RuntimeError('the VAT reader failed')
    monkeypatch.setattr(vat, 'vat_due', broken)
    standing = app.test_client().get('/api/dashboard/admin/standing', headers=auth_headers).get_json()
    assert standing['vat'] is None
    assert standing['positions'] is not None and standing['approvals'] is not None


def test_it_is_the_manager_s_alone(app):
    from flask import g
    from auth_decorators import generate_token
    from models import AppUser
    client = app.test_client()

    def status(role):
        user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
        db.session.add(user)
        db.session.flush()
        g.pop('current_user', None)
        return client.get('/api/dashboard/admin/standing',
                          headers={'Authorization': f'Bearer {generate_token(user)}'}).status_code
    assert status('manager') == 200
    assert status('accountant') == 403
