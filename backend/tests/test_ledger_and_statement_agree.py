"""The account's two buttons give one balance (10 Oct 2026).

The account card offers «كشف الحساب» and «دفتر الأستاذ». The ledger filtered
out deleted lines only, so it counted unposted and deleted entries the
statement leaves out: on the 10 Oct copy mada read 87,760.00 in the ledger and
0.00 in the statement, tamara 3,600.00 more, and the cash customer 2,500.00
more -- rejected invoice 3303's draft entry.

One definition of a line that counts (accounting/balances.counted_line_filters)
-- its entry posted, not a draft, not deleted, and the line not deleted -- read
by the ledger, the statement, the live balance and the stored balance.

Run:
    python -m pytest tests/test_ledger_and_statement_agree.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account():
    a = Account(account_number=f'9{uuid.uuid4().hex[:6]}', name=f'ح {uuid.uuid4().hex[:6]}', type='Asset')
    db.session.add(a)
    db.session.flush()
    return a


def _entry(account, other, amount, *, posted=True, draft=False, deleted=False, line_deleted=False):
    je = JournalEntry(entry_number=f'JE-T-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 1),
                      description='اختبار', entry_type='عادي', is_posted=posted, is_draft=draft,
                      is_deleted=deleted, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id, cash_debit=amount, cash_credit=0.0,
                         is_deleted=line_deleted, description='اختبار'),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=0.0, cash_credit=amount,
                         is_deleted=line_deleted, description='اختبار'),
    ])
    db.session.flush()


@pytest.fixture
def books():
    account, other = _account(), _account()
    _entry(account, other, 100.0)                                # counts
    _entry(account, other, 500.0, posted=False, draft=True)      # a draft -- 3303's
    _entry(account, other, 700.0, posted=False)                  # unposted, not a draft
    _entry(account, other, 900.0, deleted=True)                  # its entry deleted
    _entry(account, other, 300.0, line_deleted=True)             # its line deleted
    return account


def test_the_ledger_counts_only_what_counts(auth_headers, books):
    resp = flask_app.test_client().get(f'/api/account_ledger/{books.id}', headers=auth_headers)
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()['closing_balance']['cash'] == pytest.approx(100.0)


def test_the_ledger_with_a_start_date_opens_on_what_counts(auth_headers, books):
    resp = flask_app.test_client().get(f'/api/account_ledger/{books.id}?start_date=2026-10-02',
                                       headers=auth_headers)
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()['opening_balance']['cash'] == pytest.approx(100.0)


def test_the_ledger_the_statement_and_the_balances_agree(auth_headers, books):
    from accounting.balances import _recalculate_account_balances_for_accounts
    from services.live_balances import live_balances_by_account_ids
    client = flask_app.test_client()
    ledger = client.get(f'/api/account_ledger/{books.id}', headers=auth_headers).get_json()
    statement = client.get(f'/api/accounts/{books.id}/statement', headers=auth_headers).get_json()
    _recalculate_account_balances_for_accounts([books.id])

    assert ledger['closing_balance']['cash'] \
        == pytest.approx(statement['closing_balance_cash']) \
        == pytest.approx(live_balances_by_account_ids([books.id])[books.id]['cash']) \
        == pytest.approx(db.session.get(Account, books.id).balance_cash) \
        == pytest.approx(100.0)


@pytest.mark.xfail(strict=True, reason='Known Gap STMT-SUPPLIER-RELAXED (architecture-v1 §4.6): the supplier '
                                        'statement counts an unposted entry that is not a draft')
def test_the_supplier_statement_counts_only_what_counts(auth_headers):
    """The supplier statement's own filter is «posted OR not a draft», not the
    one definition: an unposted entry left not-a-draft (the limbo the nightly
    check reports) moves the supplier's statement and no balance. None exists
    on the 10 Oct copy. When the statement reads counted_line_filters this
    passes, and strict xfail fails the build until the marker goes."""
    from models import Supplier
    supplier = Supplier(supplier_code=f'S-{uuid.uuid4().hex[:6]}', name=f'مورد {uuid.uuid4().hex[:6]}')
    db.session.add(supplier)
    db.session.flush()
    payable = Account(account_number=f'21{uuid.uuid4().hex[:5]}', name='دائنون', type='Liability')
    other = _account()
    db.session.add(payable)
    db.session.flush()
    for amount, posted in ((100.0, True), (50.0, False)):
        je = JournalEntry(entry_number=f'JE-S-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 1),
                          description='اختبار', entry_type='عادي', is_posted=posted, is_draft=False,
                          created_by='t')
        db.session.add(je)
        db.session.flush()
        db.session.add_all([
            JournalEntryLine(journal_entry_id=je.id, account_id=payable.id, supplier_id=supplier.id,
                             cash_credit=amount, description='اختبار'),
            JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=amount,
                             description='اختبار'),
        ])
    db.session.flush()
    statement = flask_app.test_client().get(f'/api/suppliers/{supplier.id}/statement',
                                            headers=auth_headers).get_json()
    assert abs(statement['closing_balance_cash']) == pytest.approx(100.0)


def test_each_statement_line_carries_the_balance_after_it(auth_headers, books):
    """The screen shows it and never recomputes it (a filter used to restart the
    balance from the lines it left). The last line's is the closing."""
    statement = flask_app.test_client().get(f'/api/accounts/{books.id}/statement',
                                            headers=auth_headers).get_json()
    lines = statement['lines']
    assert [l['running_cash_balance'] for l in lines] == [100.0]
    assert lines[-1]['running_cash_balance'] == pytest.approx(statement['closing_balance_cash'])
    assert lines[-1]['running_gold_balance'] == pytest.approx(statement['closing_balance_gold_normalized'])


@pytest.mark.parametrize('route', ['/api/customers/{customer}/statement', '/api/suppliers/{supplier}/statement'])
def test_customer_and_supplier_statements_carry_it_too(auth_headers, route):
    from models import Customer, Supplier
    customer = Customer(name=f'عميل {uuid.uuid4().hex[:6]}', customer_code=f'C-{uuid.uuid4().hex[:6]}')
    supplier = Supplier(supplier_code=f'S-{uuid.uuid4().hex[:6]}', name=f'مورد {uuid.uuid4().hex[:6]}')
    db.session.add_all([customer, supplier])
    db.session.flush()
    receivable = Account(account_number=f'12{uuid.uuid4().hex[:5]}', name='مدينون', type='Asset')
    payable = Account(account_number=f'21{uuid.uuid4().hex[:5]}', name='دائنون', type='Liability')
    other = _account()
    db.session.add_all([receivable, payable])
    db.session.flush()
    for amount in (100.0, 250.0):
        je = JournalEntry(entry_number=f'JE-R-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 1),
                          description='اختبار', entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
        db.session.add(je)
        db.session.flush()
        db.session.add_all([
            JournalEntryLine(journal_entry_id=je.id, account_id=receivable.id, customer_id=customer.id,
                             cash_debit=amount, description='اختبار'),
            JournalEntryLine(journal_entry_id=je.id, account_id=payable.id, supplier_id=supplier.id,
                             cash_credit=amount, description='اختبار'),
            JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=0.0, description='اختبار'),
        ])
    db.session.flush()
    statement = flask_app.test_client().get(route.format(customer=customer.id, supplier=supplier.id),
                                            headers=auth_headers).get_json()
    lines = statement['lines']
    assert len(lines) == 2
    assert abs(lines[0]['running_cash_balance']) == pytest.approx(100.0)
    assert lines[-1]['running_cash_balance'] == pytest.approx(statement['closing_balance_cash'])
