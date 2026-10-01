"""A posted entry is never deleted, nor soft-deleted -- held by the database (UNPOST-001 U3).

The owner's rule (1 Oct 2026): a posted manual entry is corrected by a
reversing entry; a document's entry goes only with its document. The last line
is a PostgreSQL trigger (backend/posted_entry_trigger.py): it holds against raw
SQL, which no application check can see. Only a system reset or wipe may pass,
inside journal_entry_guard.system_purge(), and only the reset functions of
routes/system.py may call it.

Run:
    python -m pytest tests/test_posted_entry_immutable.py -v
"""
import ast
import os
import uuid
from datetime import datetime

import pytest
import sqlalchemy as sa

from app import app as flask_app
from models import JournalEntry, db

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _entry(posted):
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 10, 1),
                      description='U3', is_posted=posted)
    db.session.add(je)
    db.session.flush()
    return je.id


def _refused(sql, **params):
    """Run raw SQL in a savepoint; True if the database refused it."""
    sp = db.session.begin_nested()
    try:
        db.session.execute(sa.text(sql), params)
        sp.commit()
        return False
    except sa.exc.DBAPIError as exc:
        sp.rollback()
        assert 'cannot be' in str(exc.orig), exc
        return True


def test_raw_sql_cannot_delete_a_posted_entry():
    je = _entry(posted=True)
    assert _refused('DELETE FROM journal_entry WHERE id = :id', id=je)
    assert db.session.execute(sa.text('select count(*) from journal_entry where id = :id'), {'id': je}).scalar() == 1


def test_raw_sql_cannot_soft_delete_a_posted_entry():
    je = _entry(posted=True)
    assert _refused('UPDATE journal_entry SET is_deleted = true WHERE id = :id', id=je)


def test_raw_sql_cannot_unpost_and_delete_in_one_statement():
    je = _entry(posted=True)
    assert _refused('UPDATE journal_entry SET is_posted = false, is_deleted = true WHERE id = :id', id=je)


def test_raw_sql_cannot_truncate_the_entries():
    _entry(posted=True)
    assert _refused('TRUNCATE journal_entry CASCADE')


def test_an_unposted_entry_can_be_deleted():
    je = _entry(posted=False)
    assert not _refused('DELETE FROM journal_entry WHERE id = :id', id=je)


def test_a_system_purge_may_delete_a_posted_entry():
    from journal_entry_guard import system_purge
    je = _entry(posted=True)
    sp = db.session.begin_nested()
    with system_purge(db.session, 'test'):
        db.session.execute(sa.text('DELETE FROM journal_entry WHERE id = :id'), {'id': je})
    sp.commit()
    assert db.session.execute(sa.text('select count(*) from journal_entry where id = :id'), {'id': je}).scalar() == 0


def test_only_the_system_resets_open_the_purge():
    """The exception is confined to the known system paths: no other runtime
    module may call system_purge() or name the setting that opens the trigger."""
    allowed = {
        os.path.join(BACKEND, 'journal_entry_guard.py'),     # defines it
        os.path.join(BACKEND, 'posted_entry_trigger.py'),    # the trigger reads it
        os.path.join(BACKEND, 'routes', 'system.py'),        # the resets
    }
    skip = ('venv', 'tests', 'devtools', 'tools', 'alembic', '__pycache__')
    offenders = []
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in skip]
        for name in files:
            if not name.endswith('.py') or name.startswith('test_') or name == 'conftest.py':
                continue
            path = os.path.join(root, name)
            src = open(path, encoding='utf-8').read()
            if ('system_purge' in src or 'yasargold.system_purge' in src) and path not in allowed:
                offenders.append(os.path.relpath(path, BACKEND))
    assert offenders == []

    # And inside routes/system.py only the two resets that delete wholesale use it.
    tree = ast.parse(open(os.path.join(BACKEND, 'routes', 'system.py'), encoding='utf-8').read())
    purged = sorted(
        fn.name for fn in ast.walk(tree) if isinstance(fn, ast.FunctionDef)
        for d in fn.decorator_list
        if isinstance(d, ast.Call) and getattr(d.func, 'id', None) == '_system_purge')
    assert purged == ['_reset_full_system_wipe', '_reset_transactions']
