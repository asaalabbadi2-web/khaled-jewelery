"""The backup tools are the database's own major version (the owner, 18 Nov 2026).

Every production backup since January was written by pg_dump 17 -- the
image's distro postgresql-client (python:3.11-slim, Debian 13) -- from a
PostgreSQL 16 server. pg_restore 17 on a 16 server sets transaction_timeout,
which 16 does not know: it restores every row and exits 1, so the in-app
restore (check=True since 13 Jul 2026) said «فشل الاستعادة» and, from ADR-094,
never reached the photos. pg_restore 16 refuses the 17 archive outright.
The law: the image installs the client of one major, PG_MAJOR, and every
compose file runs the database of that major.

Run:
    python -m pytest tests/test_backup_tools_match_the_database.py -v
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _image_major():
    text = (ROOT / 'backend' / 'Dockerfile').read_text()
    arg = re.search(r'^ARG PG_MAJOR=(\d+)\s*$', text, re.M)
    assert arg, 'the Dockerfile names its client major: ARG PG_MAJOR=<n>'
    assert 'postgresql-client-${PG_MAJOR}' in text, 'the client installed is that major'
    assert not re.search(r'^\s*postgresql-client\s*\\?\s*$', text, re.M), \
        'not the distro client, whose major is the distro\'s (17 on Debian 13)'
    return int(arg.group(1))


def test_the_image_installs_the_databases_client():
    major = _image_major()
    found = {}
    for compose in sorted(ROOT.glob('docker-compose*.yml')):
        for tag in re.findall(r'image:\s*postgres:(\d+)', compose.read_text()):
            found.setdefault(int(tag), []).append(compose.name)
    assert found, 'a compose file runs the database'
    assert set(found) == {major}, f'the database majors {found} -- the image\'s client is {major}'


def test_the_nightly_check_says_a_tool_of_another_major(app):
    from sqlalchemy import text
    from models import db
    from services.books_invariants import BACKUP_TOOLS_MISMATCH, check_backup_tools_mismatch
    server = int(db.session.execute(text('SHOW server_version_num')).scalar()) // 10000
    assert check_backup_tools_mismatch(tool_major=lambda tool: server) == []
    found = check_backup_tools_mismatch(tool_major=lambda tool: server + 1)
    assert [(f.kind, f.subject_key, f.metric) for f in found] == [
        (BACKUP_TOOLS_MISMATCH, 'tool:pg_dump', server + 1.0), (BACKUP_TOOLS_MISMATCH, 'tool:pg_restore', server + 1.0)]
    assert check_backup_tools_mismatch(tool_major=lambda tool: None) == [], 'a tool missing is the backup\'s refusal'


def test_a_backup_of_a_newer_tool_is_said_in_arabic():
    from routes.system import NEWER_ARCHIVE, _restore_refusal
    assert _restore_refusal('pg_restore: error: unsupported version (1.16) in file header') == NEWER_ARCHIVE
    assert _restore_refusal('pg_restore: error: connection refused') is None
