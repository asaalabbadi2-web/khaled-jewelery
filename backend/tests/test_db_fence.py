"""The test fence holds: nothing a test writes survives it, not even a commit (TEST-001).

Run:
    python -m pytest tests/test_db_fence.py -v
"""
import pathlib
import uuid

import pytest

from app import app as flask_app
from models import Account, db

MARK = 'fence-' + uuid.uuid4().hex[:8]


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


def test_a_commit_inside_the_fence_is_visible_there(db_fence):
    db.session.add(Account(account_number=MARK[:15], name=MARK, type='Asset'))
    db.session.commit()
    assert Account.query.filter_by(name=MARK).count() == 1


def test_and_gone_after_it():
    assert Account.query.filter_by(name=MARK).count() == 0, 'a commit leaked out of the fence'


def test_a_commit_through_a_route_is_fenced_too(db_fence, auth_headers):
    """The code under test commits through its own request: still inside."""
    before = Account.query.count()
    resp = flask_app.test_client().post('/api/accounts', headers=auth_headers, json={
        'account_number': MARK[:12] + '9', 'name': MARK + '-route', 'type': 'Asset'})
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:200]
    assert Account.query.count() == before + 1


def test_and_that_is_gone_too():
    assert Account.query.filter_by(name=MARK + '-route').count() == 0


def test_no_module_keeps_its_own_broken_fence():
    """`db.session.bind = connection` is the pattern that never isolated anything."""
    tests_dir = pathlib.Path(__file__).parent
    offenders = [p.name for p in tests_dir.glob('test_*.py')
                 if p.name != pathlib.Path(__file__).name
                 and 'db.session.bind = connection' in p.read_text(encoding='utf-8')]
    assert offenders == [], offenders
