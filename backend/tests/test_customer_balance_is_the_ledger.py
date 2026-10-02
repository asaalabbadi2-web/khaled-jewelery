"""A customer's balance is the ledger's, read one way everywhere (BALANCE-001 B1, the owner 2 Oct 2026).

Three numbers for «عميل نقدي» #8 on the 2 Oct copy: the customers screen
showed the cached column (−2,790,158.17); the statement read only the lines
TAGGED with the customer (1,476,486.31) and missed the untagged ones on its
own account (the collections, about −1.39 M); the account in the ledger said
70,261.82. All sales are cash: what stands is residue of a few invoices left
open (stage 4), not credit.

The owner's rule, the suppliers' own: a customer's balance is every posted
line on the customer's own financial account, tagged or not, plus the lines
tagged to them on shared customer accounts (12…). Cash only -- the weight
memo twin (712…) accumulates the dual system's weights, not gold a customer
owes. The list, the statement and the dashboard read it; the law: the list's
balance is the statement's closing balance is the ledger's.

Run:
    python -m pytest tests/test_customer_balance_is_the_ledger.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import Account, Customer, JournalEntry, JournalEntryLine, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number, name):
    acc = Account(account_number=number, name=name, type='Asset')
    db.session.add(acc)
    db.session.flush()
    return acc


def _entry(lines):
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 9, 1), description='t',
                      is_posted=True, reference_type='invoice', reference_id=0)
    db.session.add(je)
    db.session.flush()
    for account_id, debit, credit, customer_id in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account_id, cash_debit=debit,
                                        cash_credit=credit, customer_id=customer_id))
    db.session.flush()


@pytest.fixture
def ledger():
    n = uuid.uuid4().int % 10**5
    own = _account(f'12{n:05d}1', 'عميل نقدي اختبار')
    other_own = _account(f'12{n:05d}2', 'عميل آخر')
    shared = _account(f'12{n:05d}3', 'عملاء مشترك')
    revenue = _account(f'4{n:05d}', 'إيراد')
    me = Customer(customer_code=f'C-{uuid.uuid4().hex[:6]}', name='عميل نقدي', account_id=own.id,
                  balance_cash=-2790158.17)                       # the cached column, wrong
    other = Customer(customer_code=f'C-{uuid.uuid4().hex[:6]}', name='آخر', account_id=other_own.id)
    db.session.add_all([me, other])
    db.session.flush()
    _entry([(own.id, 1000.0, 0.0, me.id), (revenue.id, 0.0, 1000.0, None)])          # a sale, tagged
    _entry([(own.id, 0.0, 900.0, None), (revenue.id, 900.0, 0.0, None)])             # its collection, untagged
    _entry([(shared.id, 300.0, 0.0, me.id), (revenue.id, 0.0, 300.0, None)])         # tagged on a shared account
    _entry([(other_own.id, 50.0, 0.0, me.id), (revenue.id, 0.0, 50.0, None)])        # tagged on another's own
    return me, 1000.0 - 900.0 + 300.0                                                # 400.0


def _get(path, headers):
    g.pop('current_user', None)
    return flask_app.test_client().get(path, headers=headers)


def test_the_list_shows_the_ledger_not_the_cached_column(auth_headers, ledger):
    me, expected = ledger
    rows = _get('/api/customers', auth_headers).get_json()
    assert next(r for r in rows if r['id'] == me.id)['balance_cash'] == expected


def test_the_statement_closes_on_the_same_balance(auth_headers, ledger):
    me, expected = ledger
    body = _get(f'/api/customers/{me.id}/statement', auth_headers).get_json()
    assert round(body['closing_balance_cash'], 2) == expected


def test_the_reader_is_one(ledger):
    from services.party_live_balances import compute_live_customer_balances
    me, expected = ledger
    assert compute_live_customer_balances([me])[me.id]['cash'] == expected
