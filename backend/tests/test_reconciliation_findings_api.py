"""HTTP contract for reading reconciliation findings, and the nightly job's wiring.

The endpoint is read-only and sits behind reports.financial: findings name
entries, vouchers and safe boxes with their amounts, which is financial data.

Run:
    python -m pytest tests/test_reconciliation_findings_api.py -v
"""
import json
import uuid

import pytest

from app import app, db
from auth_decorators import generate_token
from models import Permission, ReconciliationFinding, Role, User

ENDPOINT = '/api/reconciliation/findings'


def _headers_for(*permission_codes):
    suffix = uuid.uuid4().hex[:8]
    user = User(username=f'rf_{suffix}', full_name='findings reader', is_active=True, is_admin=False)
    user.set_password('x')
    db.session.add(user)
    db.session.flush()
    if permission_codes:
        role = Role(name=f'rf_role_{suffix}', name_ar='دور اختبار', is_active=True)
        db.session.add(role)
        db.session.flush()
        for code in permission_codes:
            perm = Permission.query.filter_by(code=code).first()
            if perm is None:
                perm = Permission(code=code, name=code, name_ar=code, category='reports', is_active=True)
                db.session.add(perm)
                db.session.flush()
            role.permissions.append(perm)
        user.roles.append(role)
    db.session.commit()
    return {'Authorization': f'Bearer {generate_token(user)}'}


@pytest.fixture
def seeded():
    """Two findings of our own, removed afterwards so nothing leaks."""
    with app.app_context():
        tag = uuid.uuid4().hex[:8]
        a = ReconciliationFinding(kind='ORPHAN_POSTED_ENTRY', source='books_invariants',
                                  subject_key=f'journal_entry:test-{tag}', metric=24.2,
                                  detail=json.dumps({'entry_number': 'REV-TEST'}))
        b = ReconciliationFinding(kind='SAFEBOX_SUBLEDGER_DRIFT', source='books_invariants',
                                  subject_key=f'safe_box:test-{tag}', metric=-2000.0,
                                  detail=json.dumps({'difference': -2000.0}))
        db.session.add_all([a, b])
        db.session.commit()
        ids = (a.id, b.id)
        yield {'tag': tag, 'ids': ids}
        ReconciliationFinding.query.filter(ReconciliationFinding.id.in_(ids)).delete(
            synchronize_session=False)
        db.session.commit()


def test_open_findings_are_listed_with_their_detail_parsed(seeded):
    with app.app_context():
        headers = _headers_for('reports.financial')
    with app.test_client() as c:
        resp = c.get(ENDPOINT, headers=headers)
    assert resp.status_code == 200
    body = resp.get_json()
    mine = [f for f in body['findings'] if seeded['tag'] in (f['subject_key'] or '')]
    assert {f['kind'] for f in mine} == {'ORPHAN_POSTED_ENTRY', 'SAFEBOX_SUBLEDGER_DRIFT'}
    orphan = next(f for f in mine if f['kind'] == 'ORPHAN_POSTED_ENTRY')
    assert orphan['detail'] == {'entry_number': 'REV-TEST'}, 'detail is returned as data, not a string'
    assert orphan['metric'] == 24.2


def test_filtering_by_kind(seeded):
    with app.app_context():
        headers = _headers_for('reports.financial')
    with app.test_client() as c:
        resp = c.get(f'{ENDPOINT}?kind=SAFEBOX_SUBLEDGER_DRIFT', headers=headers)
    kinds = {f['kind'] for f in resp.get_json()['findings']}
    assert kinds <= {'SAFEBOX_SUBLEDGER_DRIFT'}


def test_an_unknown_status_is_refused():
    with app.app_context():
        headers = _headers_for('reports.financial')
    with app.test_client() as c:
        assert c.get(f'{ENDPOINT}?status=everything', headers=headers).status_code == 400


def test_reading_needs_financial_reports_permission(monkeypatch):
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')
    with app.app_context():
        headers = _headers_for('safe_boxes.view')
    with app.test_client() as c:
        assert c.get(ENDPOINT, headers=headers).status_code == 403


def test_anonymous_callers_are_refused(monkeypatch):
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')
    with app.test_client() as c:
        assert c.get(ENDPOINT).status_code == 401


def test_the_endpoint_offers_no_way_to_change_a_finding():
    """Read-only surface: resolving reviewed findings comes later, with a screen."""
    rules = [r for r in app.url_map.iter_rules() if r.rule.startswith(ENDPOINT)]
    assert rules and all(r.methods <= {'GET', 'HEAD', 'OPTIONS'} for r in rules)


class TestNightlyWiring:

    def test_the_job_is_registered(self):
        from schedulers import _SCHEDULER_STARTERS
        assert 'books_invariants' in _SCHEDULER_STARTERS

    def test_the_job_is_optional_not_critical(self):
        """A report-only job must never be the reason money stops moving: a
        critical scheduler that fails to start takes the whole process down."""
        from schedulers import _CRITICAL
        assert 'books_invariants' not in _CRITICAL

    def test_it_runs_after_the_backup_and_the_safebox_job(self):
        from books_invariants_scheduler import BooksInvariantsScheduler
        from safebox_reconciliation_scheduler import SafeboxReconciliationScheduler
        assert BooksInvariantsScheduler.RUN_AT > SafeboxReconciliationScheduler.RUN_AT
