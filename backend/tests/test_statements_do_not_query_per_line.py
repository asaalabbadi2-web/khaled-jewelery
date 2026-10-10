"""A statement asks the database a fixed number of questions, however long it is (10 Oct 2026).

Measured on the 10 Oct copy: the cash customer's account statement -- 4,941
lines -- sent 44,499 queries and took 15.7 s; the ledger 68,119 and 24.4 s.
Two causes, one each per line: the main karat read from Settings again for
each karat conversion (about eight a line), and the line's entry loaded on
its own. Now: 20 queries and 0.5 s; the ledger 3 queries.

The main karat stays live (§13): read once per request, so a change to the
setting holds from the next request.

Run:
    python -m pytest tests/test_statements_do_not_query_per_line.py -v
"""
import uuid
from datetime import datetime

import pytest
from sqlalchemy import event

from app import app as flask_app
from models import Account, Customer, JournalEntry, JournalEntryLine, Settings, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number=None):
    a = Account(account_number=number or f'9{uuid.uuid4().hex[:6]}', name=f'ح {uuid.uuid4().hex[:6]}',
                type='Asset')
    db.session.add(a)
    db.session.flush()
    return a


def _lines(account, other, n, *, customer_id=None):
    for i in range(n):
        je = JournalEntry(entry_number=f'JE-Q-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 1, 9, i % 60),
                          description='اختبار', entry_type='عادي', is_posted=True, is_draft=False,
                          created_by='t')
        db.session.add(je)
        db.session.flush()
        db.session.add_all([
            JournalEntryLine(journal_entry_id=je.id, account_id=account.id, customer_id=customer_id,
                             cash_debit=10.0, debit_21k=1.0, description='اختبار'),
            JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_credit=10.0, credit_21k=1.0,
                             description='اختبار'),
        ])
    db.session.flush()


def _queries(path, headers):
    """Queries of one request, after one to warm the per-process caches (the
    column checks of core.database are read once a process)."""
    flask_app.test_client().get(path, headers=headers)
    count = [0]

    def counter(*_):
        count[0] += 1

    event.listen(db.engine, 'before_cursor_execute', counter)
    try:
        resp = flask_app.test_client().get(path, headers=headers)
    finally:
        event.remove(db.engine, 'before_cursor_execute', counter)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return count[0]


@pytest.mark.parametrize('route', ['/api/accounts/{id}/statement', '/api/account_ledger/{id}'])
def test_an_account_statement_and_the_ledger_do_not_query_per_line(auth_headers, route):
    account, other = _account(), _account()
    _lines(account, other, 3)
    short = _queries(route.format(id=account.id), auth_headers)
    _lines(account, other, 40)
    long = _queries(route.format(id=account.id), auth_headers)
    assert long == short, f'{short} queries for 3 lines, {long} for 43'


def test_a_customer_statement_does_not_query_per_line(auth_headers):
    customer = Customer(name=f'عميل {uuid.uuid4().hex[:6]}', customer_code=f'C-{uuid.uuid4().hex[:6]}')
    db.session.add(customer)
    db.session.flush()
    receivable, other = _account(f'12{uuid.uuid4().hex[:5]}'), _account()
    _lines(receivable, other, 3, customer_id=customer.id)
    short = _queries(f'/api/customers/{customer.id}/statement', auth_headers)
    _lines(receivable, other, 40, customer_id=customer.id)
    long = _queries(f'/api/customers/{customer.id}/statement', auth_headers)
    assert long == short, f'{short} queries for 3 lines, {long} for 43'


def test_the_main_karat_is_read_once_a_request_and_a_change_holds_from_the_next(auth_headers):
    """§13: live, not frozen -- only not re-read eight times a line."""
    from pricing.gold_price_service import get_main_karat
    settings = Settings.query.first() or Settings()
    db.session.add(settings)
    settings.main_karat = 21
    db.session.flush()
    with flask_app.test_request_context('/'):
        assert get_main_karat() == 21
        settings.main_karat = 18
        db.session.flush()
        assert get_main_karat() == 21, 'within the request it was read once'
    with flask_app.test_request_context('/'):
        assert get_main_karat() == 18, 'the next request reads the change'
    assert get_main_karat() == 18, 'outside a request it is read each time'


def test_the_request_that_changes_the_main_karat_reads_the_new_one():
    from pricing.gold_price_service import forget_main_karat, get_main_karat
    settings = Settings.query.first() or Settings()
    db.session.add(settings)
    settings.main_karat = 21
    db.session.flush()
    with flask_app.test_request_context('/'):
        assert get_main_karat() == 21
        settings.main_karat = 24
        db.session.flush()
        forget_main_karat()                 # as PUT /api/settings does
        assert get_main_karat() == 24
