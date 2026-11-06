"""A closed year's archive answers, and writes nothing (ADR-044 phase 2).

The owner, 12 Oct 2026: «نسخة ثانية من النظام للقراءة فقط برابط منفصل، على قاعدة
2026 المقفلة»; 7 Nov: every user with his permissions, on port 8080. The
application runs on the closed year's database with ARCHIVE_YEAR set: every
writing request is refused -- signing in, out and its token's renewal aside,
which the read-only database role also leaves writable
(ops/archive/readonly_role.sql). The year is said on check-setup, so the
screens can say it before anyone signs in.

Run:
    python -m pytest tests/test_archive_read_only.py -v
"""
import pytest

from app import app as flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def archive(monkeypatch):
    monkeypatch.setenv('ARCHIVE_YEAR', '2026')


def _client():
    return flask_app.test_client()


def test_a_write_is_refused_in_the_archive(archive, auth_headers):
    for method, path in (('post', '/api/invoices'), ('put', '/api/opening/2027/1'), ('delete', '/api/vouchers/1'),
                         ('patch', '/api/auth/me/photo')):
        resp = getattr(_client(), method)(path, headers=auth_headers, json={})
        assert resp.status_code == 403, (method, path, resp.status_code)
        body = resp.get_json()
        assert body['error'] == 'archive_read_only' and '2026' in body['message'], (method, path)


def test_reading_and_signing_in_are_not(archive, auth_headers):
    assert _client().get('/api/auth/me', headers=auth_headers).status_code == 200
    resp = _client().post('/api/auth/login', json={'username': 'nobody-here', 'password': 'x'})
    assert resp.status_code != 403 or resp.get_json().get('error') != 'archive_read_only'
    resp = _client().post('/api/auth/logout', headers=auth_headers, json={})
    assert (resp.get_json() or {}).get('error') != 'archive_read_only'


def test_the_year_is_said_before_signing_in(archive):
    assert _client().get('/api/auth/check-setup').get_json()['archive_year'] == 2026


def test_outside_the_archive_nothing_changes(auth_headers):
    assert _client().get('/api/auth/check-setup').get_json()['archive_year'] is None
    resp = _client().post('/api/invoices', headers=auth_headers, json={})
    assert (resp.get_json() or {}).get('error') != 'archive_read_only'


def test_the_archive_fetches_no_price_into_itself(archive, auth_headers):
    """Its last price is 31 Dec's, old by any clock: a working year fetches a
    new one on reading (ADR-065); the archive shows its own."""
    from sqlalchemy import event
    from models import db
    from tests.test_reads_write_nothing import SIGN_IN_TABLES, WRITE
    writes = []

    def watch(conn, cursor, statement, *args):
        m = WRITE.match(statement)
        if m and m.group(2).lower() not in SIGN_IN_TABLES:
            writes.append(f'{m.group(1)} {m.group(2)}')
    db.session.flush()
    event.listen(db.engine, 'before_cursor_execute', watch)
    try:
        for path in ('/api/gold_price', '/api/public/gold_price'):
            _client().get(path, headers=auth_headers)
    finally:
        event.remove(db.engine, 'before_cursor_execute', watch)
    assert writes == []
