"""Grams left on a cash account move to its weight twin (ADR-051) -- the repair.

Run:
    python -m pytest tests/test_repair_weight_to_weight_twin.py -v
"""
import datetime as dt
import uuid

import pytest

from account_pair_service import link_accounts
from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from services.live_balances import live_balances_by_account_ids
from services.repair.weight_to_weight_twin import move_grams_to_weight_twin


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(weight):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name=f'حساب {uuid.uuid4().hex[:5]}',
                type='Liability', transaction_type='gold' if weight else 'cash', tracks_weight=weight)
    db.session.add(a)
    db.session.flush()
    return a


def test_the_calibration_s_21k_moves_to_the_weight_account_once(app):
    cash, gold = _account(False), _account(True)
    link_accounts(cash, gold, created_by='test')
    je = JournalEntry(entry_number=f'JE-CAL-{uuid.uuid4().hex[:8]}', date=dt.datetime(2026, 10, 12), is_posted=True,
                      description='معايرة ذهب عيار ١٨ الى عيار ٢١', entry_type='عادي', created_by='admin')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([   # as JE-2026-06478 was written
        JournalEntryLine(journal_entry_id=je.id, account_id=gold.id, credit_18k=1956.7, description=''),
        JournalEntryLine(journal_entry_id=je.id, account_id=cash.id, debit_21k=1677.171, description='')])
    db.session.flush()
    now = dt.datetime(2026, 10, 18, 9)

    dry = [p for p in move_grams_to_weight_twin(by='t', now=now, dry_run=True) if p['entry'] == je.entry_number]
    assert dry == [{'entry': je.entry_number, 'date': je.date, 'account': cash.account_number,
                    'grams': {'21k': 1677.171}, 'twin': gold.account_number}]

    move_grams_to_weight_twin(by='t', now=now, dry_run=False)
    db.session.expire_all()
    live = live_balances_by_account_ids([cash.id, gold.id])
    assert live[cash.id]['21k'] == pytest.approx(0.0)
    assert (live[gold.id]['18k'], live[gold.id]['21k']) == (pytest.approx(-1956.7), pytest.approx(1677.171))

    again = move_grams_to_weight_twin(by='t', now=now, dry_run=False)
    assert [p.get('done') for p in again if p['entry'] == je.entry_number] == [True]   # a second run writes nothing
    assert not [p for p in again if p['account'] == cash.account_number and not p.get('done')]  # nor moves its own undo
    db.session.expire_all()
    assert live_balances_by_account_ids([cash.id])[cash.id]['21k'] == pytest.approx(0.0)
    assert JournalEntry.query.filter_by(reference_type='stage4_reclassification', reference_id=je.id).count() == 1
