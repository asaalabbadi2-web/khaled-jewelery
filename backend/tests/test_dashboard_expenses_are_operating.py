"""The dashboard's «المصروفات» are the operating expenses (the owner, 11 Oct 2026).

They summed the debits of every 5-account: 18,995,723.96 for 2026 on the 10 Oct
copy -- 10.1 million of scrap purchases (512) and 7.4 million of cost of sales
(51) among them, reversals never subtracted, drafts and deleted lines counted --
and the screen took sales - purchases - that for «صافي الربح»: a loss of 21
million. Now: group 5 without the 51 subtree, net, by the one definition of a
line that counts. 776,885.09 for 2026 on the copy.

Run:
    python -m pytest tests/test_dashboard_expenses_are_operating.py -v
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


def _account(number, name, parent=None, type_='Expense'):
    found = Account.query.filter_by(account_number=number).first()
    if found:
        return found
    a = Account(account_number=number, name=name, type=type_, parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _child(parent, name):
    a = Account(account_number=f'{parent.account_number}9{uuid.uuid4().int % 10**6}', name=name,
                type='Expense', parent_id=parent.id)
    db.session.add(a)
    db.session.flush()
    return a


def _entry(account, other, debit=0.0, credit=0.0, *, posted=True, draft=False, deleted=False, line_deleted=False):
    je = JournalEntry(entry_number=f'JE-X-{uuid.uuid4().hex[:8]}', date=datetime.now(), description='اختبار',
                      entry_type='عادي', is_posted=posted, is_draft=draft, is_deleted=deleted, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id, cash_debit=debit, cash_credit=credit,
                         is_deleted=line_deleted, description='اختبار'),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=credit, cash_credit=debit,
                         is_deleted=line_deleted, description='اختبار'),
    ])
    db.session.flush()


@pytest.fixture
def chart():
    expenses = _account('5', 'المصروفات')
    cost_of_sales = _account('51', 'تكلفة المبيعات', expenses)
    operating = _account('52', 'مصاريف تشغيلية', expenses)
    cash = Account(account_number=f'9{uuid.uuid4().hex[:6]}', name='صندوق', type='Asset')
    db.session.add(cash)
    db.session.flush()
    return {'rent': _child(operating, 'إيجار اختبار'), 'scrap': _child(cost_of_sales, 'مشتريات كسر اختبار'),
            'cash': cash}


def _month_expenses(headers):
    body = flask_app.test_client().get('/api/dashboard/admin', headers=headers).get_json()
    return body['sales_purchases_summary']['month']['expenses']


def test_only_operating_expenses_count_net_of_reversals(auth_headers, chart):
    before = _month_expenses(auth_headers)['total_value']
    _entry(chart['rent'], chart['cash'], debit=1000.0)                     # rent: counts
    _entry(chart['rent'], chart['cash'], credit=200.0)                     # its reversal: subtracted
    _entry(chart['scrap'], chart['cash'], debit=50000.0)                   # scrap purchase: cost of sales, not expense
    _entry(chart['rent'], chart['cash'], debit=700.0, posted=False, draft=True)   # a draft: not counted
    _entry(chart['rent'], chart['cash'], debit=900.0, deleted=True)        # a deleted entry: not counted
    _entry(chart['rent'], chart['cash'], debit=300.0, line_deleted=True)   # a deleted line: not counted

    after = _month_expenses(auth_headers)
    assert after['total_value'] - before == pytest.approx(800.0)
    names = {a['account'] for a in after['by_account']}
    assert 'إيجار اختبار' in names and 'مشتريات كسر اختبار' not in names


def test_the_operating_accounts_follow_the_chart_tree(chart):
    from services.income_accounts import operating_expense_account_ids
    ids = operating_expense_account_ids()
    assert chart['rent'].id in ids
    assert chart['scrap'].id not in ids, 'under 51 «تكلفة المبيعات»'
    assert Account.query.filter_by(account_number='51').first().id not in ids


def test_the_expenses_say_how_many_entries_make_them(auth_headers, chart):
    """The owner (12 Oct 2026): «المصروفات أيضًا في تبويبها ليس هناك تفاصيل لها».
    The tab shows its details when its count is not zero -- and the expenses
    never sent one: the tab read empty while its accounts were there. The count
    is the entries that make the period's operating expenses, as counted."""
    before = _month_expenses(auth_headers).get('docs', 0)
    _entry(chart['rent'], chart['cash'], debit=1000.0)
    _entry(chart['rent'], chart['cash'], credit=200.0)
    _entry(chart['scrap'], chart['cash'], debit=50000.0)                   # not an operating expense
    _entry(chart['rent'], chart['cash'], debit=700.0, posted=False, draft=True)
    after = _month_expenses(auth_headers)
    assert after['docs'] - before == 2
