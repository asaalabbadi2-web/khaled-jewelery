"""CHART-002 step 4c3: an account no correction may touch is marked so -- the mark
follows the account, its number does not matter (2027 renumbers, ADR-044).
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, db
from services.repair.entries import ProtectedAccount, substitute_ids, write_entry

NOW = datetime(2026, 10, 14, 22, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number=None, **marks):
    a = Account(account_number=number or f'9{uuid.uuid4().int % 10**7:07d}', name='حساب', type='Asset',
                transaction_type='cash', **marks)
    db.session.add(a)
    db.session.flush()
    return a


def _correct(account, other):
    return write_entry(date=datetime(2026, 10, 1), description='t', reference_type='t', reference_id=None,
                       lines=[{'account_id': account.id, 'cash_debit': 1.0}, {'account_id': other.id, 'cash_credit': 1.0}],
                       by='t', now=NOW)


def test_a_marked_account_is_refused_whatever_its_number():
    with pytest.raises(ProtectedAccount):
        _correct(_account(repair_protected=True), _account())


def test_an_unmarked_account_is_corrected_whatever_its_number():
    old_main_cash = Account.query.filter_by(account_number='1100000').first() or _account('1100000')
    old_main_cash.repair_protected = False
    db.session.flush()
    assert _correct(old_main_cash, _account()).id


def test_the_substitute_is_the_marked_accounts_own():
    reserve = _account()
    main = _account(repair_protected=True, repair_substitute_id=reserve.id)
    assert substitute_ids()[main.id] == reserve.id
