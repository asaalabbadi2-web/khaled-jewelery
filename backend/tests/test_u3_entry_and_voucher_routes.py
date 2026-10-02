"""Who may delete an entry or cancel a voucher, and the API's early refusals (UNPOST-001 U3).

Until 1 Oct 2026 the hard delete of an entry, and cancelling or deleting a
voucher, checked no permission at all: any signed-in user, any role. The
owner's decisions:
  - journal.delete (the system admin) for deleting an entry, and only an
    unposted manual one -- a posted entry is reversed, a document's entry goes
    with its document;
  - vouchers.cancel for the system admin and the manager -- not the accountant
    until the voucher lifecycle is characterised;
  - vouchers.delete for the system admin.
The routes refuse early and readably (409); journal_entry_guard and the
database trigger hold regardless (tests/test_document_entry_guard.py,
tests/test_posted_entry_immutable.py).

Run:
    python -m pytest tests/test_u3_entry_and_voucher_routes.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, JournalEntry, Voucher, db
from tests.retraction_world import _create, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _headers_for(role):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _manual_entry(posted):
    je = JournalEntry(entry_number=f'M-{uuid.uuid4().hex[:10]}', date=datetime(2026, 10, 1),
                      description='يدوي', is_posted=posted)
    db.session.add(je)
    db.session.flush()
    return je.id


def _client():
    return flask_app.test_client()


@pytest.mark.parametrize('role', ['manager', 'accountant', 'employee'])
def test_only_journal_delete_may_hard_delete_an_entry(role):
    je = _manual_entry(posted=False)
    assert _client().delete(f'/api/journal_entries/{je}', headers=_headers_for(role)).status_code == 403


def test_the_system_admin_deletes_an_unposted_manual_entry(auth_headers):
    je = _manual_entry(posted=False)
    assert _client().delete(f'/api/journal_entries/{je}', headers=auth_headers).status_code == 200


def test_a_posted_manual_entry_is_reversed_not_deleted(auth_headers):
    je = _manual_entry(posted=True)
    for resp in (_client().delete(f'/api/journal_entries/{je}', headers=auth_headers),
                 _client().post(f'/api/journal_entries/{je}/soft_delete', headers=auth_headers, json={})):
        assert resp.status_code == 409 and resp.get_json()['error'] == 'posted_entry'


def test_a_documents_entry_is_refused_on_every_entry_route(auth_headers, world):
    inv = _create(auth_headers, world, 'scrap_purchase_unpaid', held=False)
    je = JournalEntry.query.filter_by(reference_type='invoice', reference_id=inv['id']).first().id
    from tests.retraction_world import Settings
    row = Settings.query.first() or Settings()
    row.allow_unposting = True
    db.session.add(row)
    db.session.flush()
    calls = [
        _client().delete(f'/api/journal_entries/{je}', headers=auth_headers),
        _client().post(f'/api/journal_entries/{je}/soft_delete', headers=auth_headers, json={}),
        _client().post(f'/api/journal-entries/unpost/{je}', headers=auth_headers, json={}),
        _client().post('/api/journal-entries/unpost-batch', headers=auth_headers, json={'entry_ids': [je]}),
        _client().delete(f'/api/journal-entries/{je}', headers=auth_headers),
    ]
    assert [(c.status_code, (c.get_json() or {}).get('error')) for c in calls] == [(409, 'document_entry')] * 5
    db.session.expire_all()
    assert JournalEntry.query.get(je).is_posted is True


@pytest.mark.parametrize('role,allowed', [('manager', True), ('accountant', False), ('employee', False)])
def test_who_may_cancel_a_voucher(role, allowed):
    v = Voucher(voucher_number=f'RV-{uuid.uuid4().hex[:8]}', voucher_type='receipt', date=datetime(2026, 10, 1),
                status='pending', amount_cash=1.0)
    db.session.add(v)
    db.session.flush()
    resp = _client().post(f'/api/vouchers/{v.id}/cancel', headers=_headers_for(role), json={'reason': 'U3'})
    assert (resp.status_code != 403) is allowed, resp.get_data(as_text=True)[:200]


@pytest.mark.parametrize('role', ['accountant', 'storekeeper', 'employee'])
def test_only_the_system_admin_and_the_manager_delete_a_voucher(role):
    """U3 kept deleting a voucher to the system admin; the owner's matrix
    (ADR-036, 2 Oct 2026) gives the manager the deletion of a pending one."""
    v = Voucher(voucher_number=f'RV-{uuid.uuid4().hex[:8]}', voucher_type='receipt', date=datetime(2026, 10, 1),
                status='pending', amount_cash=1.0)
    db.session.add(v)
    db.session.flush()
    assert _client().delete(f'/api/vouchers/{v.id}', headers=_headers_for(role)).status_code == 403
