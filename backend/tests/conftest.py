# هذا الملف يُعرّف pytest على تهيئة الاختبارات
# الملفات e2e_* هي سكريبتات تُشغَّل مباشرة وليست اختبارات pytest
collect_ignore = [
    "e2e_direct_test.py",
    "e2e_invoice_test.py",
]


# ── db_fence (TEST-001) ─────────────────────────────────────────────────────
import pytest


@pytest.fixture
def db_fence(app):
    """One transaction per test that nothing escapes -- not even a commit.

    The fence copied into ~17 modules set `db.session.bind = connection`, but
    Flask-SQLAlchemy 3.1's Session.get_bind() never reads session.bind: every
    statement went to the engine, and any commit() in the code under test
    stayed in the run's database (TEST-001) -- a settings row left by one test
    broke another on 29 Sep 2026. Here:
      - the session is built on ONE connection and its get_bind() honours it;
      - join_transaction_mode='create_savepoint' turns the code's commit() into
        a savepoint release inside the outer transaction.
    The tests run on PostgreSQL (backend/conftest.py). The outer transaction is rolled back after the test. tests/test_db_fence.py
    commits inside it and finds nothing afterwards.
    """
    from flask_sqlalchemy.session import Session as FsaSession
    from models import db

    class _FencedSession(FsaSession):
        def get_bind(self, mapper=None, clause=None, bind=None, **kwargs):
            return bind if bind is not None else self.bind

    connection = db.engine.connect()
    outer = connection.begin()
    saved = db.session
    db.session = db._make_scoped_session({
        'bind': connection,
        'join_transaction_mode': 'create_savepoint',
        'class_': _FencedSession,
    })
    try:
        yield db.session
    finally:
        db.session.remove()
        db.session = saved
        outer.rollback()
        connection.close()
