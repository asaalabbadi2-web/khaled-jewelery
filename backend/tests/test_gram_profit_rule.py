"""Which accounts gram profit counts: every revenue and expense, but trading and what the owner takes out (ADR-092).

The owner (17 Nov 2026): «وسم الحسابات التي تدخل في حسابه وجدت بعضها غير مفعل
في الواجهة وعند تفعيله لم يؤثر في الإجمالي». An account counted when it or a
parent was marked; the switch showed its own mark only -- salaries and rent
counted through 52 with their switch off -- and the weight twin of a purity
gain, under the sales' weight group, went uncounted while its loss counted.
Now:
  - every revenue and expense account counts, with its weight twin;
  - but trading -- the accounts the invoices post to, by their roles, and their
    twins -- which the first layer reads from the invoices;
  - and what the owner excludes: an account with all under it, a twin with
    its cash account (zakat: excluded, and the owner may put it back);
  - the server says each account's standing and what decided it.

Run:
    python -m pytest tests/test_gram_profit_rule.py -v
"""
import uuid

import pytest

from accounting.chart_tree import EXPENSES_ROOT, OPERATING_REVENUE_ROOT, REVENUE_ROOT, role_account_id
from models import Account, AccountingMapping, db
from services.gram_profit_accounts import gram_profit_accounts


@pytest.fixture
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def fenced(app, db_fence):
    yield


def _account(name, parent_id, *, kind, twin_parent_id=None):
    """A cash account under *parent_id*, and its weight twin under *twin_parent_id*."""
    tag = uuid.uuid4().hex[:6]
    twin = None
    if twin_parent_id is not None:
        twin = Account(account_number=f'7T{tag}', name=f'{name} وزني', type=kind, tracks_weight=True,
                       parent_id=twin_parent_id)
        db.session.add(twin)
        db.session.flush()
    account = Account(account_number=f'T{tag}', name=name, type=kind, tracks_weight=False,
                      parent_id=parent_id, memo_account_id=twin.id if twin else None)
    db.session.add(account)
    db.session.flush()
    return account, twin


def _twin_of(role):
    return db.session.get(Account, role_account_id(role)).memo_account_id


def _counted():
    revenue, expense = gram_profit_accounts()
    return revenue | expense


def test_an_expense_counts_unmarked_and_its_weight_twin_with_it(fenced):
    group, group_twin = _account('مجموعة مصاريف', role_account_id(EXPENSES_ROOT), kind='Expense',
                                 twin_parent_id=_twin_of(EXPENSES_ROOT))
    salaries, salaries_twin = _account('رواتب', group.id, kind='Expense', twin_parent_id=group_twin.id)
    revenue, expense = gram_profit_accounts()
    assert {salaries.id, salaries_twin.id, group.id} <= expense, 'no mark asked'
    assert not ({salaries.id, salaries_twin.id} & revenue)


def test_trading_is_known_by_its_role_and_its_twin_by_it(fenced):
    operating = role_account_id(OPERATING_REVENUE_ROOT)
    sales, sales_twin = _account('مبيعات اختبار', operating, kind='Revenue', twin_parent_id=_twin_of(OPERATING_REVENUE_ROOT))
    db.session.add(AccountingMapping(operation_type=f'اختبار-{uuid.uuid4().hex[:6]}', account_type='sales_gold_scrap',
                                     account_id=sales.id, is_active=True))
    # A gain under the sales' groups that is not trading: counted, its twin too.
    gain, gain_twin = _account('فرق نقاوة مكسب', operating, kind='Revenue', twin_parent_id=_twin_of(OPERATING_REVENUE_ROOT))
    db.session.flush()
    counted = _counted()
    assert not ({sales.id, sales_twin.id, operating, _twin_of(OPERATING_REVENUE_ROOT)} & counted), 'trading'
    assert {gain.id, gain_twin.id} <= counted, 'its place under 41/741 does not make it trading'


def test_an_excluded_group_takes_all_under_it_and_their_twins_and_can_be_put_back(fenced):
    zakat_group, zakat_group_twin = _account('الزكاة', role_account_id(EXPENSES_ROOT), kind='Expense',
                                             twin_parent_id=_twin_of(EXPENSES_ROOT))
    zakat, zakat_twin = _account('مصروف الزكاة', zakat_group.id, kind='Expense', twin_parent_id=zakat_group_twin.id)
    zakat_group.exclude_from_gram_profit = True
    db.session.flush()
    assert not ({zakat_group.id, zakat.id, zakat_twin.id, zakat_group_twin.id} & _counted())
    zakat_group.exclude_from_gram_profit = False
    db.session.flush()
    assert {zakat_group.id, zakat.id, zakat_twin.id} <= _counted(), 'the owner puts it back'


def test_the_old_mark_decides_nothing(fenced):
    marked, _ = _account('إيراد موسوم', role_account_id(REVENUE_ROOT), kind='Revenue')
    marked.include_in_gram_profit = True
    marked.exclude_from_gram_profit = True
    db.session.flush()
    assert marked.id not in _counted(), 'excluded wins; include_in_gram_profit is no longer read'


def test_each_account_says_its_standing_and_what_decided_it(fenced):
    from services.gram_profit_accounts import COUNTED, EXCLUDED, OUTSIDE, TRADING, gram_profit_standing
    group, group_twin = _account('مجموعة', role_account_id(EXPENSES_ROOT), kind='Expense',
                                 twin_parent_id=_twin_of(EXPENSES_ROOT))
    child, child_twin = _account('فرع', group.id, kind='Expense', twin_parent_id=group_twin.id)
    group.exclude_from_gram_profit = True
    operating = role_account_id(OPERATING_REVENUE_ROOT)
    sales, sales_twin = _account('مبيعات', operating, kind='Revenue', twin_parent_id=_twin_of(OPERATING_REVENUE_ROOT))
    db.session.add(AccountingMapping(operation_type=f'اختبار-{uuid.uuid4().hex[:6]}', account_type='revenue',
                                     account_id=sales.id, is_active=True))
    plain, _ = _account('إيراد', role_account_id(REVENUE_ROOT), kind='Revenue')
    asset, _ = _account('أصل', None, kind='Asset')
    db.session.flush()
    standing = gram_profit_standing()
    assert standing[child.id] == (EXCLUDED, 'expense', group.id)
    assert standing[child_twin.id] == (EXCLUDED, 'expense', group.id)
    assert standing[sales_twin.id] == (TRADING, 'revenue', sales.id)
    assert standing[plain.id] == (COUNTED, 'revenue', None)
    assert standing[asset.id].state == OUTSIDE


def test_the_accounts_screen_reads_the_standing(fenced, auth_headers):
    from flask import g
    from app import app as flask_app
    group, _ = _account('مجموعة للشاشة', role_account_id(EXPENSES_ROOT), kind='Expense')
    child, _ = _account('فرع للشاشة', group.id, kind='Expense')
    group.exclude_from_gram_profit = True
    db.session.flush()
    g.pop('current_user', None)
    one = flask_app.test_client().get(f'/api/accounts/{child.id}', headers=auth_headers).get_json()
    assert one['gram_profit'] == {'state': 'excluded', 'side': 'expense',
                                  'via': {'id': group.id, 'account_number': group.account_number, 'name': group.name}}
    g.pop('current_user', None)
    listed = flask_app.test_client().get('/api/accounts', headers=auth_headers).get_json()
    by_id = {a['id']: a for a in listed}
    assert by_id[group.id]['gram_profit'] == {'state': 'excluded', 'side': 'expense', 'via': None}


def test_the_queue_reads_an_unmarked_expense(fenced):
    import datetime as dt
    from models import JournalEntry, JournalEntryLine
    from services.weight_position import EXPENSE, collect_events
    rent, _ = _account('إيجار غير موسوم', role_account_id(EXPENSES_ROOT), kind='Expense')
    cash, _ = _account('صندوق', None, kind='Asset')
    when = dt.datetime(2098, 5, 15, 10)
    entry = JournalEntry(entry_number=f'JE-GP-{uuid.uuid4().hex[:6]}', date=when, description='إيجار',
                         entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(entry)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=entry.id, account_id=rent.id, cash_debit=1000.0),
                        JournalEntryLine(journal_entry_id=entry.id, account_id=cash.id, cash_credit=1000.0)])
    db.session.flush()
    events = collect_events(dt.datetime(2098, 5, 1), dt.datetime(2098, 5, 31, 23, 59))
    assert [(c.when.date(), c.cash) for c in events.closings if c.kind == EXPENSE] == [(dt.date(2098, 5, 15), 1000.0)]


def test_a_weight_account_under_the_sales_weight_group_with_no_cash_account_is_trading(fenced):
    lone = Account(account_number=f'7L{uuid.uuid4().hex[:6]}', name='مبيعات وزني بلا نظير', type='Revenue',
                   tracks_weight=True, parent_id=_twin_of(OPERATING_REVENUE_ROOT))
    db.session.add(lone)
    db.session.flush()
    assert lone.id not in _counted(), 'nothing says it is not a sale: not counted twice (D-3)'
