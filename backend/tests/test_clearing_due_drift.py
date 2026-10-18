"""The nightly check reports a card's due drifting from its clearing account (ADR-051).

The due a clearing safe is settled by (routes/clearing._compute_clearing_due_amount)
is built from the card payments and their settlement lines, with the safe-box
rows for transfers -- not from the ledger. On the 16 Oct production copy it
equals the clearing account on all five clearing safes. Rather than rewrite
the settlement, the nightly books check says so the night it stops.

Run:
    python -m pytest tests/test_clearing_due_drift.py -v
"""
import datetime as dt
import uuid

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, SafeBox, db
from services.books_invariants import CHECKS, CLEARING_DUE_DRIFT, KINDS, check_clearing_due_drift


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _clearing_safe():
    acc = Account(account_number=f'15{uuid.uuid4().int % 10**6:06d}', name='مقاصة اختبار', type='Asset')
    db.session.add(acc)
    db.session.flush()
    safe = SafeBox(name=f'مقاصة {uuid.uuid4().hex[:6]}', safe_type='clearing', account_id=acc.id, is_active=True)
    db.session.add(safe)
    db.session.flush()
    return safe


def test_a_clearing_account_the_due_does_not_know_is_reported(app):
    safe = _clearing_safe()
    # A classified entry the settlement does not know (the clearing guard asks for a type).
    je = JournalEntry(entry_number=f'JE-CD-{uuid.uuid4().hex[:8]}', date=dt.datetime(2026, 10, 1), description='تصحيح',
                      entry_type='عادي', is_posted=True, created_by='t', reference_type='manual_correction')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=safe.account_id, cash_debit=250.0,
                                    description='بلا دفعة'))
    db.session.flush()

    facts = {f.subject_key: f for f in check_clearing_due_drift()}

    fact = facts[f'safe_box:{safe.id}']
    assert fact.metric == pytest.approx(-250.0)
    assert (fact.detail['due'], fact.detail['ledger']) == (0.0, 250.0)


def test_a_clearing_safe_whose_due_is_its_account_is_quiet(app):
    safe = _clearing_safe()
    assert f'safe_box:{safe.id}' not in {f.subject_key for f in check_clearing_due_drift()}


def test_it_runs_with_the_night_s_checks():
    assert CHECKS[CLEARING_DUE_DRIFT] is check_clearing_due_drift
    assert CLEARING_DUE_DRIFT in KINDS
