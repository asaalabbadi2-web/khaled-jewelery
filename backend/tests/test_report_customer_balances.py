"""Customers' balances in riyals and gold, from the ledger -- never the weight memo (REPORTS ت5-1, ADR-083).

The owner, 4 Nov 2026 («يقرأ الدفتر الصحيح»): «أرصدة ذهب العملاء» read the
customers' weight memo twins (712…), which hold the dual system's weights --
18,805 g «owed» by 21 customers on the 2 Nov copy -- while the ledger's one
reader of a customer's balance (BALANCE-001 B1: every line on its own account,
tagged or not, and those tagged to it on a shared customer account -- cash
and the gold columns of the same lines) finds none owing gold. The report
reads that reader, on a day: each customer owing or owed, in riyals and in
grams of the main karat. What the receivables group holds that no customer
does -- an untagged line on a shared account -- is said apart, and the check
says there is none.

Run:
    python -m pytest tests/test_report_customer_balances.py -v
"""
import datetime as dt
import uuid

import pytest

from models import Account, Customer, JournalEntry, JournalEntryLine, db

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number, name, *, receivable=True, weight=False):
    from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    parent = require_account(DEFAULT_MAPPING_OPERATION_TYPE, CUSTOMER_RECEIVABLES_ROOT) if receivable else None
    acc = Account(account_number=number, name=name, type='Asset', parent_id=parent, tracks_weight=weight)
    db.session.add(acc)
    db.session.flush()
    return acc


def _entry(day, lines):
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=D(2043, 6, day, 12), description='t',
                      is_posted=True, reference_type='invoice', reference_id=0)
    db.session.add(je)
    db.session.flush()
    for account_id, cash, grams, customer_id in lines:
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=account_id, customer_id=customer_id,
            cash_debit=max(cash, 0.0), cash_credit=max(-cash, 0.0),
            debit_21k=max(grams, 0.0), credit_21k=max(-grams, 0.0)))
    db.session.flush()


@pytest.fixture
def ledger():
    n = uuid.uuid4().int % 10**5
    own = _account(f'12{n:05d}1', 'حساب عميل')
    memo = _account(f'712{n:05d}', 'حساب عميل وزني', receivable=False, weight=True)
    own.memo_account_id = memo.id
    revenue = _account(f'4{n:05d}', 'إيراد', receivable=False)
    customer = Customer(customer_code=f'C-{uuid.uuid4().hex[:6]}', name=f'عميل أرصدة {n}', account_id=own.id)
    db.session.add(customer)
    db.session.flush()
    _entry(1, [(own.id, 1000.0, 2.0, customer.id), (revenue.id, -1000.0, -2.0, None)])   # owes 1000 and 2 g
    _entry(2, [(memo.id, 0.0, 50.0, customer.id), (revenue.id, 0.0, -50.0, None)])        # the memo: not a debt
    _entry(9, [(own.id, -400.0, 0.0, None), (revenue.id, 400.0, 0.0, None)])              # pays 400, untagged
    return {'customer': customer, 'own': own}


def _report(day):
    from services.reports.customer_balances import customer_balances
    return customer_balances(as_of=dt.date(2043, 6, day), now=D(2043, 7, 1))


def _row(report, customer):
    return next(r for r in report.rows if r.get('drill') == {'kind': 'customer', 'id': customer.id})


def test_a_customer_s_balance_in_riyals_and_grams_never_the_memo(ledger):
    row = _row(_report(30), ledger['customer'])
    assert row['cash'] == pytest.approx(600.0)
    assert row['gold'] == pytest.approx(2.0), 'its own account\'s gold column, not the memo\'s 50 g'


def test_a_day_counts_whole(ledger):
    assert _row(_report(5), ledger['customer'])['cash'] == pytest.approx(1000.0)


def test_what_no_customer_holds_is_said_and_checked(ledger):
    from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    assert {c.key: c.ok for c in _report(30).checks} == {'every_line_has_its_customer': True}
    shared = Account(account_number=f'12{uuid.uuid4().int % 10**6:06d}', name='عملاء مشترك', type='Asset',
                     parent_id=require_account(DEFAULT_MAPPING_OPERATION_TYPE, CUSTOMER_RECEIVABLES_ROOT))
    db.session.add(shared)
    db.session.flush()
    _entry(10, [(shared.id, 75.0, 0.0, None)])                                            # nobody's
    report = _report(30)
    assert {c.key: c.ok for c in report.checks} == {'every_line_has_its_customer': False}
    apart = next(r for r in report.rows if r.get('style') == 'finding')
    assert apart['cash'] == pytest.approx(75.0)
