"""«تسويات وفروقات» (34) and its weight twin (734) are linked, so an account under it gets its twin (the owner, 16 Oct 2026).

On the 15 Oct 2026 copy the two groups were unlinked while their children
360 and 7360 were linked; an account added under 34 got no weight twin, and
asked for one was refused. Migration 20261016_link_settlements_group links
them -- or refuses, changing nothing, when either is linked elsewhere.
"""
import importlib.util
import uuid
from pathlib import Path

import pytest
from flask import g

from app import app as flask_app
from models import Account, db

MIGRATION = Path(__file__).resolve().parent.parent / 'alembic/versions/20261016_link_settlements_group.py'


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _migration():
    spec = importlib.util.spec_from_file_location('link_settlements_group', MIGRATION)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    class _Op:      # the migration's one use of alembic's op, on the test's session
        @staticmethod
        def get_bind():
            return db.session.connection()

    module.op = _Op
    return module


def _groups():
    """34 and 734 as on production: unlinked groups, under the equity groups."""
    for number in ('34', '734'):
        existing = Account.query.filter_by(account_number=number).first()
        if existing is not None:
            existing.account_number = f'x{uuid.uuid4().hex[:6]}'
    db.session.flush()
    fin = Account(account_number='34', name='تسويات وفروقات', type='Equity', transaction_type='cash',
                  tracks_weight=False)
    wt = Account(account_number='734', name='تسويات وفروقات وزني', type='Equity', transaction_type='gold',
                 tracks_weight=True)
    db.session.add_all([fin, wt])
    db.session.flush()
    return fin, wt


def _free_child_number():
    """A three-digit number under 34 that is free, as the accounts screen asks."""
    for n in range(370, 400):
        if not Account.query.filter(Account.account_number.in_([str(n), f'7{n}'])).first():
            return str(n)
    raise AssertionError('no free number under 34')


def _add_under(parent, auth_headers):
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/accounts', headers=auth_headers, json={
        'account_number': _free_child_number(), 'name': 'تسوية جديدة', 'type': 'Equity',
        'transaction_type': 'cash', 'parent_id': parent.id, 'create_parallel': True})


def test_unlinked_an_account_under_it_gets_no_twin(auth_headers):
    fin, _ = _groups()
    resp = _add_under(fin, auth_headers)
    body = resp.get_json() or {}
    created = Account.query.filter_by(name='تسوية جديدة', parent_id=fin.id).first()
    assert created is None or created.memo_account_id is None, body


def test_the_migration_links_them_and_an_account_under_34_gets_its_twin_under_734(auth_headers):
    fin, wt = _groups()
    _migration().upgrade()
    db.session.expire_all()
    assert db.session.get(Account, fin.id).memo_account_id == wt.id
    assert db.session.get(Account, wt.id).memo_account_id == fin.id

    resp = _add_under(fin, auth_headers)
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]
    created = Account.query.filter_by(name='تسوية جديدة', parent_id=fin.id).one()
    twin = db.session.get(Account, created.memo_account_id)
    assert twin is not None and twin.parent_id == wt.id and twin.tracks_weight

    _migration().upgrade()          # a second run finds them linked: nothing to do
    assert db.session.get(Account, fin.id).memo_account_id == wt.id


def test_linked_elsewhere_it_is_refused_and_nothing_changes():
    fin, wt = _groups()
    other = Account(account_number=f'7{uuid.uuid4().int % 10**6:06d}', name='توأم آخر', type='Equity',
                    transaction_type='gold', tracks_weight=True)
    db.session.add(other)
    db.session.flush()
    fin.memo_account_id = other.id
    db.session.flush()
    with pytest.raises(RuntimeError, match='linked to another account'):
        _migration().upgrade()
    db.session.expire_all()
    assert db.session.get(Account, wt.id).memo_account_id is None
