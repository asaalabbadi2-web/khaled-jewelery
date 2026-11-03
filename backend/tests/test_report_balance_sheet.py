"""The balance sheet: what the shop owns and owes on a day, in riyals and grams, from the tree (REPORTS ت2-1, ADR-083).

The owner, 4 Nov 2026: in riyals and in weight («أوافقك»). There was none --
no reader of the financial position anywhere. Its groups are the roots'
children (assets, liabilities, equity; through a root's only child), each
in riyals from its subtree and in grams from its weight twin's; the year's
result, not yet closed, is the revenues' and expenses' net credit, in riyals
and grams -- what the books say, so it balances. It checks itself: assets
equal liabilities, equity and the result, in riyals and in grams; and no
weight account holds riyals (on the 2 Nov copy 634,899.15 sat on the scrap
stock's weight account 71310). Every line opens its account.

Run:
    python -m pytest tests/test_report_balance_sheet.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, db

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _group(role):
    """A group of *role*'s root -- the test chart's first, or one made under the root,
    with its weight twin under the root's twin."""
    from accounting.chart_tree import role_account_id, twin_id
    from services.reports.balance_sheet import groups_of
    root = role_account_id(role)
    found = groups_of(root)
    if found:
        return found[0]
    twin = Account(account_number=f'78{uuid.uuid4().int % 10**8:08d}', name='مجموعة وزني', type='Asset',
                   parent_id=twin_id(root))
    db.session.add(twin)
    db.session.flush()
    group = Account(account_number=f'18{uuid.uuid4().int % 10**8:08d}', name='مجموعة', type='Asset',
                    parent_id=root, memo_account_id=twin.id)
    db.session.add(group)
    db.session.flush()
    return group


def _child(role, name):
    """A fresh account under a group of *role*'s root, with a weight twin under its twin."""
    from accounting.chart_tree import twin_id
    group = _group(role)
    twin_parent = twin_id(group.id)
    weight = Account(account_number=f'79{uuid.uuid4().int % 10**8:08d}', name=f'{name} وزني', type='Asset',
                     parent_id=twin_parent)
    db.session.add(weight)
    db.session.flush()
    account = Account(account_number=f'19{uuid.uuid4().int % 10**8:08d}', name=name, type='Asset',
                      parent_id=group.id, memo_account_id=weight.id)
    db.session.add(account)
    db.session.flush()
    return account, group


def _entry(when, lines):
    from dual_system_helpers import create_dual_journal_entry
    entry = JournalEntry(date=when, description='ميزانية', entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(entry)
    db.session.flush()
    for account_id, kw in lines:
        create_dual_journal_entry(journal_entry_id=entry.id, account_id=account_id, apply_golden_rule=False, **kw)
    db.session.flush()


def _sheet(day):
    from services.reports.balance_sheet import balance_sheet
    return balance_sheet(as_of=day, now=D(2041, 12, 31))


def _checks(report):
    return {c.key: c.ok for c in report.checks}


def test_it_balances_in_riyals_and_grams_and_a_sale_moves_the_result():
    from accounting.chart_tree import ASSETS_ROOT, REVENUE_ROOT
    cash, group = _child(ASSETS_ROOT, 'صندوق ميزانية')
    revenue = _group(REVENUE_ROOT)
    before = _sheet(dt.date(2041, 6, 1))
    _entry(D(2041, 6, 5, 15), [(cash.id, {'cash_debit': 700.0, 'debit_21k': 2.0}),
                               (revenue.id, {'cash_credit': 700.0}),
                               (revenue.id, {'credit_21k': 2.0})])
    after = _sheet(dt.date(2041, 6, 5))
    assert _checks(after)['balanced_cash'] and _checks(after)['balanced_weight']
    # a group with no lines is not shown: none is its zero
    line = lambda r: next((x for x in r.rows if x.get('account_id') == group.id), {'cash': 0.0, 'weight': 0.0})  # noqa: E731,E501
    assert line(after)['cash'] - line(before)['cash'] == pytest.approx(700.0), 'its day counts whole'
    assert line(after)['weight'] - line(before)['weight'] == pytest.approx(2.0)
    result = lambda r: next(x for x in r.rows if x.get('key') == 'result')  # noqa: E731
    assert result(after)['cash'] - result(before)['cash'] == pytest.approx(700.0)
    assert line(after)['drill'] == {'kind': 'account', 'id': group.id}


def test_a_day_before_does_not_see_the_entry():
    from accounting.chart_tree import ASSETS_ROOT, REVENUE_ROOT
    cash, group = _child(ASSETS_ROOT, 'صندوق ميزانية ب')
    revenue = _group(REVENUE_ROOT)
    before = _sheet(dt.date(2041, 7, 1))
    _entry(D(2041, 7, 2, 9), [(cash.id, {'cash_debit': 50.0}), (revenue.id, {'cash_credit': 50.0})])
    on_the_first = _sheet(dt.date(2041, 7, 1))
    # a group with no lines is not shown: none is its zero
    line = lambda r: next((x for x in r.rows if x.get('account_id') == group.id), {'cash': 0.0, 'weight': 0.0})  # noqa: E731,E501
    assert line(on_the_first)['cash'] == pytest.approx(line(before)['cash'])


def test_riyals_on_a_weight_account_are_said():
    from accounting.chart_tree import ASSETS_ROOT, LIABILITIES_ROOT
    stock, _ = _child(ASSETS_ROOT, 'مخزون ميزانية')
    payable = _group(LIABILITIES_ROOT)
    _entry(D(2041, 8, 3), [(stock.memo_account_id, {'cash_debit': 120.0}), (payable.id, {'cash_credit': 120.0})])
    report = _sheet(dt.date(2041, 8, 31))
    assert _checks(report)['no_riyals_on_weight'] is False
    stray = next(x for x in report.rows if x.get('key') == 'riyals_on_weight')
    assert stray['cash'] >= 120.0
    assert _checks(report)['balanced_cash'], 'said apart, it still balances'


def test_the_route_answers_the_contract(auth_headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/reports/balance-sheet?as_of=2041-06-30', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['id'] == 'balance_sheet' and body['basis'] == 'posted_entries'
    assert body['period'] == {'start': None, 'end': '2041-06-30'}
    styles = {r.get('style') for r in body['rows']}
    assert {'heading', 'subtotal'} <= styles, 'its sections said as such'
    assert {c['key'] for c in body['columns']} >= {'name', 'cash', 'weight'}
    g.pop('current_user', None)
    assert flask_app.test_client().get('/api/reports/balance-sheet?as_of=x',
                                       headers=auth_headers).status_code == 400


def test_a_group_s_grams_are_its_accounts_twins_too():
    """On the 2 Nov copy the suppliers' 183.527 g sat on the twins of each
    supplier's account (72100020 is 2100020's), not under the group 21's own
    twin: read by the group's twin alone, they fell outside every group."""
    from accounting.chart_tree import LIABILITIES_ROOT
    group = _group(LIABILITIES_ROOT)
    loose = Account(account_number=f'77{uuid.uuid4().int % 10**8:08d}', name='مورد وزني بلا أب', type='Liability')
    db.session.add(loose)
    db.session.flush()
    supplier = Account(account_number=f'17{uuid.uuid4().int % 10**8:08d}', name='مورد', type='Liability',
                       parent_id=group.id, memo_account_id=loose.id)
    db.session.add(supplier)
    db.session.flush()
    stock, _ = _child('assets_root', 'مخزون وزن مورد')
    _entry(D(2041, 9, 4), [(stock.memo_account_id, {'debit_21k': 3.0}), (loose.id, {'credit_21k': 3.0})])
    report = _sheet(dt.date(2041, 9, 30))
    row = next(x for x in report.rows if x.get('account_id') == group.id)
    assert row['weight'] >= 3.0 - 1e-9, 'the supplier\'s grams under his group'
