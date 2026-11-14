"""Every writer of the books under the period lock (ADR-090, phase 2).

The guard sits on the JournalEntry and JournalEntryLine mappers, so every ORM
writer passes it; the database trigger holds the rest. What this file holds:

  - no runtime code writes entries past the mappers (bulk ORM writes, raw SQL)
    but the one known startup backfill, which touches no row on production;
  - a writer dated by its document (a voucher's approval, a recurring entry)
    is refused in a closed month, and the request answers 409 period_closed
    whatever the route made of it -- many routes catch every exception;
  - the correction of a closed month's document goes in the open month: a
    voucher approved in October is cancelled in November, its reversal dated
    then, its own entry untouched.

The inventory of the writers by where their date comes from is in ADR-090
(phase 2).

Run:
    python -m pytest tests/test_period_lock_writers.py -v
"""
import logging
import os
import re
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from models import JournalEntry, Voucher, db
from period_lock_guard import REQUEST_KEY, PeriodClosed, answered_readably
from services.period_lock import move
from tests.voucher_world import auto_post, create, vworld  # noqa: F401 (fixture)

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OCTOBER = date(2026, 10, 31)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _lock():
    move(OCTOBER, reason='test', by='tester', now=datetime(2026, 11, 14, 10, 0))


# ── nothing writes past the mappers ───────────────────────────────────────────

# The runtime writes past the mappers, each with why it may stay. The trigger
# holds them all, and the request answers 409 in the guard's words
# (period_lock_guard._the_trigger_refused).
KNOWN_RAW = {
    # A startup backfill of a column, in a try that swallows a refusal; it
    # touches no row on production (created_at never null, ref_1112c, 14 Nov 2026).
    ('schema_guard.py', 'UPDATE journal_entry SET created_at = date WHERE created_at IS NULL'),
    # An invoice's edit and deletion remove its entries' lines in bulk, then the
    # entries through the ORM: an invoice of a closed month is refused by both.
    ('routes/invoices.py', 'JournalEntryLine.query.filter_by(journal_entry_id=je.id).delete('),
    ('routes/invoices.py', 'JournalEntryLine.query.filter_by(journal_entry_id=vje_id).delete('),
    # The system's resets, inside system_purge(): the one exception (law 9).
    ('routes/system.py', 'JournalEntry.query.delete('),
    ('routes/system.py', 'JournalEntryLine.query.delete('),
    ('routes/system.py', 'query(JournalEntryLine).update('),
}

_SKIP_DIRS = {'tests', 'venv', 'alembic', 'migrations', '__pycache__', '_archived', 'graphify-out', 'backups',
              'instance', 'temp_pdfs', 'devtools'}
_BULK = re.compile(r'JournalEntry(?:Line)?\.query\b[^\n]*\.(?:update|delete)\(|'
                   r'query\(JournalEntry(?:Line)?\)[^\n]*\.(?:update|delete)\(')
_RAW = re.compile(r'(?:UPDATE|DELETE\s+FROM|INSERT\s+INTO)\s+journal_entry(?:_line)?\b[^"\']*', re.I)


def test_no_runtime_code_writes_entries_past_the_mappers():
    found = set()
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in _SKIP_DIRS]
        for name in files:
            if not name.endswith('.py') or name.startswith('test_') or name in ('conftest.py',):
                continue
            if name in ('period_lock_trigger.py', 'posted_entry_trigger.py', 'account_status_trigger.py'):
                continue                                  # the triggers themselves
            path = os.path.join(root, name)
            src = open(path, encoding='utf-8').read()
            rel = os.path.relpath(path, BACKEND)
            for m in _BULK.finditer(src):
                found.add((rel, m.group(0).strip()))
            for m in _RAW.finditer(src):
                found.add((rel, m.group(0).strip()))
    assert found == KNOWN_RAW


# ── a writer dated by its document, refused readably ─────────────────────────

def test_a_pending_voucher_of_a_closed_month_is_not_approved_and_says_why(auth_headers, vworld):
    auto_post(False)
    vid = create(auth_headers, vworld, 'cash_payment')        # dated 1 Oct 2026, pending
    _lock()
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api/vouchers/{vid}/approve', headers=auth_headers, json={})
    assert resp.status_code == 409, resp.get_json()
    assert resp.get_json()['error'] == 'period_closed'
    assert '2026-10-01' in resp.get_json()['message']


def test_a_recurring_entry_into_a_closed_month_is_refused_and_says_why(auth_headers):
    from models import Account
    from recurring_journal_system import create_recurring_template
    leaves = [a.id for a in Account.query.filter(~Account.id.in_(
        db.session.query(Account.parent_id).filter(Account.parent_id.isnot(None)))).order_by(Account.id).limit(2)]
    template = create_recurring_template('إيجار', 'إيجار شهري', 'monthly', datetime(2026, 10, 1), [
        {'account_id': leaves[0], 'cash_debit': 100}, {'account_id': leaves[1], 'cash_credit': 100}])
    _lock()
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api/recurring_templates/{template.id}/create_entry', headers=auth_headers)
    assert resp.status_code == 409, resp.get_json()
    assert resp.get_json()['error'] == 'period_closed'


# ── the correction goes in the open month ─────────────────────────────────────

def test_an_october_voucher_is_cancelled_in_november_its_entry_untouched(auth_headers, vworld):
    auto_post(True)
    vid = create(auth_headers, vworld, 'cash_payment')        # dated 1 Oct 2026, approved at creation
    entry_id = db.session.get(Voucher, vid).journal_entry_id
    _lock()
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api/vouchers/{vid}/cancel', headers=auth_headers, json={'reason': 'خطأ'})
    assert resp.status_code == 200, resp.get_json()
    reversal = JournalEntry.query.filter_by(reference_type='voucher_reversal', reference_id=vid).one()
    assert reversal.date.date() > OCTOBER
    entry = db.session.get(JournalEntry, entry_id)
    assert entry.is_posted and not entry.is_deleted


# ── the central answer ────────────────────────────────────────────────────────

def test_whatever_a_route_made_of_the_refusal_the_request_answers_409(caplog):
    refused = PeriodClosed('مقفلة')
    with flask_app.test_request_context('/api/x', method='POST'):
        from flask import request
        request.environ[REQUEST_KEY] = refused
        broad = flask_app.response_class('{"error": "Failed"}', status=500, mimetype='application/json')
        answered = answered_readably(broad)
        assert answered.status_code == 409 and answered.get_json() == {'error': 'period_closed', 'message': 'مقفلة'}

        swallowed = flask_app.response_class('{}', status=200, mimetype='application/json')
        with caplog.at_level(logging.ERROR):
            assert answered_readably(swallowed, logger=logging.getLogger('t')).status_code == 200
        assert 'period_closed swallowed' in caplog.text

    with flask_app.test_request_context('/api/x'):
        untouched = flask_app.response_class('{}', status=500)
        assert answered_readably(untouched) is untouched          # no refusal: as the route answered


def test_a_write_past_the_mappers_refused_by_the_trigger_answers_in_the_same_words():
    import sqlalchemy as sa
    from models import Account, JournalEntryLine
    je = JournalEntry(entry_number='PLW-1', date=datetime(2026, 10, 15), description='bulk')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=Account.query.first().id, cash_debit=5))
    db.session.flush()
    _lock()
    with flask_app.test_request_context('/api/invoices/1', method='PUT'):
        sp = db.session.begin_nested()
        with pytest.raises(sa.exc.DBAPIError):           # the bulk delete an invoice's edit makes
            JournalEntryLine.query.filter_by(journal_entry_id=je.id).delete()
        sp.rollback()
        answered = answered_readably(flask_app.response_class('{"error": "Failed"}', status=500))
        assert answered.status_code == 409
        assert answered.get_json()['error'] == 'period_closed'
        assert '2026-10-15' in answered.get_json()['message'] and '2026-10-31' in answered.get_json()['message']
