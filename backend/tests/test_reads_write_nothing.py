"""A read writes nothing (ADR-044 phase 2: the closed year's archive).

The archive signs in with a role that reads everything and writes only the
sign-in's own rows (ops/archive/readonly_role.sql). A GET that writes -- even a
row it flushes and the request then drops -- is refused there by the database:
/api/gold-costing/scrap made its missing costing row on every reading (the 7
Nov rehearsal on the 5 Nov copy: «permission denied for table
inventory_costing_config»). This calls every GET route that takes no id and
watches the statements: an INSERT, UPDATE or DELETE outside the sign-in's
tables fails, by route.

Run:
    python -m pytest tests/test_reads_write_nothing.py -v
"""
import re

import pytest
from sqlalchemy import event

from app import app as flask_app
from models import db

# what signing in writes -- the archive's role writes these too (ops/archive/readonly_role.sql)
SIGN_IN_TABLES = {'app_user', 'users', 'refresh_tokens', 'session_activity', 'token_blacklist', 'audit_logs',
                  'login_attempts'}
WRITE = re.compile(r'^\s*(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"?(\w+)"?', re.IGNORECASE)
# a GET that is not a reading -- kept out by name, each with its reason
NOT_A_READING = {
    '/api/system/backup/download': 'writes a file, not a row; the archive keeps its own backups off',
    # a stale price is fetched and saved on reading (ADR-065) -- in a working
    # year; the archive fetches nothing (tests/test_archive_read_only.py)
    '/api/gold_price': 'refreshes a stale price in a working year, never in the archive',
    '/api/public/gold_price': 'the same, for the sign-in screen',
}


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _reads():
    return sorted(r.rule for r in flask_app.url_map.iter_rules()
                  if 'GET' in r.methods and r.rule.startswith('/api/') and '<' not in r.rule
                  and r.rule not in NOT_A_READING)


def test_no_get_route_writes_a_row(auth_headers):
    written = {}
    current = {'route': None}

    def watch(conn, cursor, statement, parameters, context, executemany):
        m = WRITE.match(statement)
        if m and m.group(2).lower() not in SIGN_IN_TABLES and current['route']:
            written.setdefault(current['route'], set()).add(f'{m.group(1).split()[0].upper()} {m.group(2)}')

    db.session.flush()                     # the fixtures' own rows, before the watch
    engine = db.engine
    event.listen(engine, 'before_cursor_execute', watch)
    try:
        client = flask_app.test_client()
        for route in _reads():
            current['route'] = route
            client.get(route, headers=auth_headers)
            db.session.rollback()          # a failed reading leaves the fence's session usable
        current['route'] = None
    finally:
        event.remove(engine, 'before_cursor_execute', watch)
    assert written == {}, {k: sorted(v) for k, v in written.items()}
