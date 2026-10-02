"""Whether a gold safe holds enough is the ledger's answer -- the balance the screen shows (BALANCE-001 B2).

The gold transfer, the karat correction and the melting renewal summed the
safe-box ledger's rows to decide sufficiency, while the safes screen shows the
posted ledger's balance (`services/live_balances.safe_box_balance`, «the one
official balance») -- and the two differ where gold drifted (8 open
SAFEBOX_GOLD_DRIFT findings on the 2 Oct copy). The cash transfer read the
ledger already. The law: the three read the ledger, one function.

Stones have no ledger weight; their sufficiency stays on the safe-box rows.

Run:
    python -m pytest tests/test_gold_sufficiency_is_the_ledger.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _gold_safe(name):
    acc = Account(account_number=f'7{uuid.uuid4().int % 10**7:07d}', name=name, type='Asset', tracks_weight=True)
    db.session.add(acc)
    db.session.flush()
    box = SafeBox(name=f'{name} {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id, is_active=True)
    db.session.add(box)
    db.session.flush()
    return box


def _ledger_21k(box, grams):
    """The posted ledger says the safe holds *grams* of 21k."""
    other = Account(account_number=f'8{uuid.uuid4().int % 10**7:07d}', name='مقابل', type='Asset', tracks_weight=True)
    db.session.add(other)
    db.session.flush()
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 9, 1), description='t',
                      is_posted=True)
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, debit_21k=grams),
                        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, credit_21k=grams)])
    db.session.flush()


def _rows_21k(box, grams):
    """The safe-box ledger's rows say *grams* of 21k."""
    db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='opening', ref_id=0, direction='in',
                                      weight_21k=grams, created_by='t'))
    db.session.flush()


def _post(path, headers, body):
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=headers, json=body)


@pytest.mark.parametrize('ledger,rows,ok', [(5.0, 0.0, True), (1.0, 5.0, False)],
                         ids=['the ledger holds it, the rows do not', 'the rows hold it, the ledger does not'])
def test_the_gold_transfer_asks_the_ledger(auth_headers, ledger, rows, ok):
    source, target = _gold_safe('مصدر'), _gold_safe('هدف')
    _ledger_21k(source, ledger)
    _rows_21k(source, rows)
    resp = _post('/api/safe-boxes/transfer-voucher', auth_headers,
                 {'from_safe_box_id': source.id, 'to_safe_box_id': target.id, 'weights': {'21k': 2.0}})
    assert (resp.status_code in (200, 201)) is ok, resp.get_data(as_text=True)[:300]
    if not ok:
        assert resp.get_json()['available'] == 1.0


@pytest.mark.parametrize('ledger,rows,ok', [(5.0, 0.0, True), (1.0, 5.0, False)],
                         ids=['the ledger holds it, the rows do not', 'the rows hold it, the ledger does not'])
def test_the_karat_correction_asks_the_ledger(auth_headers, ledger, rows, ok):
    box = _gold_safe('تصحيح')
    _ledger_21k(box, ledger)
    _rows_21k(box, rows)
    resp = _post(f'/api/safe-boxes/{box.id}/correct-karat', auth_headers,
                 {'from_karat': 21, 'to_karat': 18, 'weight': 2.0})
    refused = resp.status_code == 400 and (resp.get_json() or {}).get('error') == 'insufficient_balance'
    assert refused is (not ok), resp.get_data(as_text=True)[:300]


def test_the_melting_renewal_asks_the_ledger(auth_headers):
    source, target = _gold_safe('صهر'), _gold_safe('ناتج')
    _ledger_21k(source, 1.0)
    _rows_21k(source, 5.0)
    resp = _post('/api/melting-renewal', auth_headers,
                 {'operation_type': 'melting', 'from_safe_box_id': source.id, 'to_safe_box_id': target.id,
                  'from_karat': 21, 'gold_weight': 2.0})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'insufficient_balance', \
        resp.get_data(as_text=True)[:300]
