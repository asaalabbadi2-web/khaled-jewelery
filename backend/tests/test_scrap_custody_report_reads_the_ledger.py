"""The scrap custody report reads the ledger, not the safe rows (ADR-051, BALANCE-001).

/reports/employee_scrap_ledger summed SafeBoxTransaction rows for each
employee's gold safe and for the main one -- a second book that, on the 16 Oct
production copy, said 180.3 g of 18k in the main scrap safe where the ledger
says 125.9. The law (BALANCE-001): a balance shown is the ledger's. A period
is the entries' dates.

Run:
    python -m pytest tests/test_scrap_custody_report_reads_the_ledger.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, Employee, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _entry(account, grams, when):
    je = JournalEntry(entry_number=f'JE-SC-{uuid.uuid4().hex[:8]}', date=when, description='عهدة',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, debit_21k=grams,
                                    description='عهدة'))
    db.session.flush()


def test_an_employee_s_custody_is_the_ledger_s_and_a_period_its_entries(auth_headers):
    account = Account(account_number=f'7131{uuid.uuid4().int % 10**5:05d}', name='عهدة اختبار', type='Asset',
                      transaction_type='gold', tracks_weight=True)
    db.session.add(account)
    db.session.flush()
    safe = SafeBox(name=f'عهدة {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=account.id, is_active=True)
    db.session.add(safe)
    db.session.flush()
    emp = Employee(employee_code=f'EMP-T-{uuid.uuid4().hex[:6]}', name=f'موظف {uuid.uuid4().hex[:4]}',
                   gold_safe_box_id=safe.id, is_active=True)
    db.session.add(emp)
    db.session.flush()
    _entry(account, 10.0, dt.datetime(2037, 3, 1, 10))
    _entry(account, 4.0, dt.datetime(2037, 3, 20, 10))
    # A safe row the ledger does not have -- the second book's drift.
    db.session.add(SafeBoxTransaction(safe_box_id=safe.id, direction='in', amount_cash=0.0, weight_21k=99.0,
                                      ref_type='drift', created_at=dt.datetime(2037, 3, 5)))
    db.session.flush()

    def report(**params):
        g.pop('current_user', None)
        resp = flask_app.test_client().get('/api/reports/employee_scrap_ledger', headers=auth_headers,
                                           query_string={'include_unassigned': 'false', **params})
        assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
        return next(r for r in resp.get_json()['rows'] if r['safe_box_id'] == safe.id)

    assert report()['weights_by_karat']['21k'] == 14.0
    assert report(start_date='2037-03-10', end_date='2037-03-31')['weights_by_karat']['21k'] == 4.0
