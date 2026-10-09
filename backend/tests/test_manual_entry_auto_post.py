"""A manual entry follows «ترحيل القيود تلقائيًا», and only the system admin turns it (the owner, 9 Oct 2026).

Creating a manual entry read the auto-post setting through `Settings`, a name
routes/journals.py never imported: the NameError was swallowed and no manual
entry was ever posted at creation, whatever the setting said. And the check
behind it allowed only the system admin to auto-post.

The owner's rule:
  - the setting on: a manual entry is posted when it is created, whoever
    creates it -- the setting is the company's deliberate choice;
  - the setting off: who creates does not post (ADR-036 R4) -- another posts it;
  - the setting is changed by the system admin alone, even for a user granted
    the settings permission.

Run:
    python -m pytest tests/test_manual_entry_auto_post.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import Account, AppUser, JournalEntry, Permission, Role, Settings, User, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, monkeypatch):
    monkeypatch.setattr(db.session, 'commit', db.session.flush)
    yield


def _role_headers(role):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}, user.username


def _settings(auto_post):
    row = Settings.query.first() or Settings()
    db.session.add(row)
    row.auto_post_entries = auto_post
    db.session.flush()
    return row


def _create(headers):
    leaves = [a.id for a in Account.query.filter(~Account.id.in_(
        db.session.query(Account.parent_id).filter(Account.parent_id.isnot(None)))).order_by(Account.id).limit(2)]
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/journal_entries', headers=headers, json={
        'date': '2026-10-09T00:00:00', 'description': 'قيد يدوي',
        'lines': [{'account_id': leaves[0], 'cash_debit': 10.0}, {'account_id': leaves[1], 'cash_credit': 10.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return db.session.get(JournalEntry, resp.get_json()['id'])


def test_the_setting_on_posts_the_entry_whoever_creates_it():
    _settings(True)
    headers, _ = _role_headers('accountant')
    entry = _create(headers)
    assert entry.is_posted is True


def test_the_setting_off_leaves_it_for_another_to_post():
    _settings(False)
    headers, _ = _role_headers('accountant')
    entry = _create(headers)
    assert entry.is_posted is False
    g.pop('current_user', None)
    own = flask_app.test_client().post(f'/api/journal-entries/post/{entry.id}', headers=headers, json={})
    assert own.status_code == 403 and own.get_json()['error'] == 'own_document'
    other, _ = _role_headers('manager')
    g.pop('current_user', None)
    posted = flask_app.test_client().post(f'/api/journal-entries/post/{entry.id}', headers=other, json={})
    assert posted.status_code == 200, posted.get_data(as_text=True)[:300]


def test_the_system_admin_too_waits_when_the_setting_is_off(auth_headers):
    _settings(False)
    assert _create(auth_headers).is_posted is False


def _granted(*codes):
    suffix = uuid.uuid4().hex[:8]
    user = User(username=f'grant_{suffix}', full_name='granted', is_active=True, is_admin=False)
    user.set_password('x')
    db.session.add(user)
    db.session.flush()
    role = Role(name=f'grant_role_{suffix}', name_ar='دور اختبار', is_active=True)
    db.session.add(role)
    db.session.flush()
    for code in codes:
        perm = Permission.query.filter_by(code=code).first() or Permission(
            code=code, name=code, name_ar=code, category='system', is_active=True)
        db.session.add(perm)
        db.session.flush()
        role.permissions.append(perm)
    user.roles.append(role)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def test_only_the_system_admin_turns_the_setting(auth_headers):
    row = _settings(True)
    granted = _granted('system.settings')
    g.pop('current_user', None)
    refused = flask_app.test_client().put('/api/settings', headers=granted, json={'auto_post_entries': False})
    assert refused.status_code == 403 and refused.get_json()['error'] == 'auto_post_entries_owner_only'
    assert row.auto_post_entries is True
    g.pop('current_user', None)
    other_setting = flask_app.test_client().put('/api/settings', headers=granted, json={'currency_symbol': 'ر.س'})
    assert other_setting.status_code == 200, 'the rest of the settings stay the settings permission\'s'
    g.pop('current_user', None)
    ok = flask_app.test_client().put('/api/settings', headers=auth_headers, json={'auto_post_entries': False})
    assert ok.status_code == 200 and Settings.query.first().auto_post_entries is False
