"""The cash flow: where the riyals came from and where they went, by the direct method (REPORTS ت2-3, ADR-083).

Cash is the group «النقدية والبنوك» -- the cash role's parent, its whole
subtree: the safes, the banks, the employees' cash custody. Each entry that
moves it gives its cash to the accounts on the other side, each by its own
net (an entry balances: the cash moved is the others' net), and those
accounts say the activity -- financing equity, investing the non-current
assets, operating the rest -- and the line, by their group in the tree. A
transfer between two cash accounts moves no cash. The flow checks itself:
the cash before + the flow = the cash after.

Run:
    python -m pytest tests/test_report_cash_flow.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, db
from tests.test_report_balance_sheet import _group

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _cash_account(name):
    from accounting.chart_tree import CASH_ROOT, role_account_id
    parent = db.session.get(Account, role_account_id(CASH_ROOT)).parent_id
    account = Account(account_number=f'11{uuid.uuid4().int % 10**8:08d}', name=name, type='Asset', parent_id=parent)
    db.session.add(account)
    db.session.flush()
    return account


def _entry(when, debit, credit, amount):
    from dual_system_helpers import create_dual_journal_entry
    entry = JournalEntry(date=when, description='تدفق', entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(entry)
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=debit.id, cash_debit=amount,
                              apply_golden_rule=False)
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=credit.id, cash_credit=amount,
                              apply_golden_rule=False)
    db.session.flush()


@pytest.fixture
def books():
    cash, bank = _cash_account('صندوق تدفق'), _cash_account('بنك تدفق')
    revenue, expense = _group('revenue_root'), _group('expenses_root')
    equity, payable = _group('equity_root'), _group('liabilities_root')
    _entry(D(2042, 3, 2, 10), cash, revenue, 1000.0)          # a sale: in
    _entry(D(2042, 3, 3, 10), expense, cash, 300.0)           # an expense: out
    _entry(D(2042, 3, 31, 18), cash, equity, 5000.0)          # the owner's capital, its last day: financing
    _entry(D(2042, 3, 4, 10), bank, cash, 200.0)              # a transfer: no flow
    _entry(D(2042, 3, 5, 10), expense, payable, 50.0)         # no cash: not here
    _entry(D(2042, 2, 20, 10), cash, revenue, 70.0)           # before the period: its opening
    return {'revenue': revenue, 'expense': expense, 'equity': equity, 'payable': payable}


def _flow():
    from services.reports.cash_flow import cash_flow
    return cash_flow(start=dt.date(2042, 3, 1), end=dt.date(2042, 3, 31), now=D(2042, 4, 1))


def _row(report, key):
    return next(r for r in report.rows if r.get('key') == key)


def test_each_entry_s_cash_goes_to_its_other_side_by_activity(books):
    report = _flow()
    assert _row(report, 'operating_total')['net'] == pytest.approx(700.0), '1,000 in, 300 out'
    assert _row(report, 'financing_total')['net'] == pytest.approx(5000.0), 'the capital, its day whole'
    assert _row(report, 'investing_total')['net'] == pytest.approx(0.0)
    assert _row(report, 'net_change')['net'] == pytest.approx(5700.0), 'the transfer moved no cash'
    revenue = next(r for r in report.rows if r.get('account_id') == books['revenue'].id)
    assert (revenue['inflow'], revenue['outflow']) == (pytest.approx(1000.0), pytest.approx(0.0))
    assert revenue['drill'] == {'kind': 'account', 'id': books['revenue'].id}
    assert not any(r.get('account_id') == books['payable'].id for r in report.rows), 'no cash, no line'


def test_it_checks_itself_the_cash_before_and_the_flow_make_the_cash_after(books):
    report = _flow()
    opening, closing = _row(report, 'opening')['net'], _row(report, 'closing')['net']
    assert closing - opening == pytest.approx(5700.0)
    assert {c.key: c.ok for c in report.checks} == {'flow_closes': True}


def test_the_route_answers_the_contract(auth_headers, books):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/reports/cash-flow?start_date=2042-03-01&end_date=2042-03-31',
                                       headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['id'] == 'cash_flow' and body['basis'] == 'posted_entries'
    assert {c['key'] for c in body['columns']} >= {'name', 'inflow', 'outflow', 'net'}
    g.pop('current_user', None)
    assert flask_app.test_client().get('/api/reports/cash-flow', headers=auth_headers).status_code == 400
