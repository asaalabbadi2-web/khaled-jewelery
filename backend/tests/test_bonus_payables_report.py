"""«المكافآت المستحقة»: the payable's balance is the books'.

The report read account 215 (there is none -- the payable is 2310, an account
per employee under it) from voucher lines, and labelled it 2310; its screen
called a path that does not exist and no button opened it (found 14 Oct 2026).
It reads the account the bonuses post to (the one finder) with the accounts
under it, from the counted journal lines -- and the reports centre opens it.
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db

NOW = datetime(2026, 10, 14, 10, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _payable():
    from bonus_routes import _find_bonus_payable_account
    payable = _find_bonus_payable_account()
    if payable is None:
        payable = Account(account_number='2310', name='مكافآت مستحقة للموظفين', type='Liability')
        db.session.add(payable)
        db.session.flush()
    return payable


def _entry(account, *, credit=0.0, debit=0.0, posted=True):
    uid = uuid.uuid4().hex[:8]
    je = JournalEntry(entry_number=f'JE-B-{uid}', date=NOW, description='مكافأة', entry_type='عادي',
                      is_posted=posted, is_draft=not posted, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='مكافأة',
                                    cash_credit=credit, cash_debit=debit))
    db.session.flush()


def _report(headers):
    resp = flask_app.test_client().get('/api/bonuses/payables-report?as_of=2026-10-31', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def _apart(body):
    """What the payables hold beside the employees' accounts (REPORTS ت6-3)."""
    return next((r['books'] for r in body['rows'] if r.get('style') == 'finding' and r.get('drill') is None), 0.0)


def test_the_payable_is_the_books_with_the_employees_accounts(app, auth_headers):
    """In the reports' contract since REPORTS ت6-3: an account under the payable
    held by no employee is said apart, from the counted lines."""
    payable = _payable()
    before = _apart(_report(auth_headers))
    loose = Account(account_number=f'2310{uuid.uuid4().hex[:4]}', name='ح/ذمم موظف - مكافآت',
                    type='Liability', parent_id=payable.id)
    db.session.add(loose)
    db.session.flush()
    _entry(loose, credit=150.0)          # an approved bonus owed
    _entry(loose, debit=40.0)            # part paid
    _entry(loose, credit=999.0, posted=False)   # a draft does not count

    body = _report(auth_headers)
    assert body['id'] == 'bonus_payables'
    assert _apart(body) == pytest.approx(before + 110.0)
