"""The income statement classifies by the chart tree (the owner, 11 Oct 2026).

It classified by number prefixes -- «50», «52», «520» as cost of sales, which
is the chart's operating group (52 «مصاريف تشغيلية»), and 51 «تكلفة
المبيعات» with its children as operating -- so on the 10 Oct copy 2026's gross
profit (18,418,966.84) exceeded its revenue (11,080,055.70). And it read
«posted or NULL», counting drafts and deleted lines. Now: revenue is group 4,
cost of sales the 51 subtree, operating the rest of 5; the lines by the one
definition. 2026's gross profit on the copy: 352,947.44; net unchanged.

Run:
    python -m pytest tests/test_income_statement_by_the_tree.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from tests.test_dashboard_expenses_are_operating import _account, _child


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


DAY = datetime(2031, 3, 15)   # a day of its own: nothing else in the test database


def _post(account, other, *, debit=0.0, credit=0.0, posted=True, draft=False, line_deleted=False):
    je = JournalEntry(entry_number=f'JE-I-{uuid.uuid4().hex[:8]}', date=DAY, description='اختبار',
                      entry_type='عادي', is_posted=posted, is_draft=draft, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id, cash_debit=debit, cash_credit=credit,
                         is_deleted=line_deleted, description='اختبار'),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=credit, cash_credit=debit,
                         is_deleted=line_deleted, description='اختبار'),
    ])
    db.session.flush()


def test_cost_of_sales_is_the_51_subtree_and_gross_profit_follows(auth_headers):
    revenue_root = _account('4', 'الإيرادات', type_='Revenue')
    sales = _child(revenue_root, 'مبيعات اختبار')
    expenses = _account('5', 'المصروفات')
    cost_root = _account('51', 'تكلفة المبيعات', expenses)
    operating_root = _account('52', 'مصاريف تشغيلية', expenses)
    scrap = _child(cost_root, 'مشتريات كسر اختبار')
    rent = _child(operating_root, 'إيجار اختبار')
    cash = Account(account_number=f'9{uuid.uuid4().hex[:6]}', name='صندوق', type='Asset')
    db.session.add(cash)
    db.session.flush()

    _post(sales, cash, credit=10000.0)                       # revenue
    _post(scrap, cash, debit=7000.0)                         # cost of sales (under 51)
    _post(rent, cash, debit=1000.0)                          # operating (under 52)
    _post(rent, cash, debit=500.0, posted=False, draft=True)  # a draft: not counted
    _post(scrap, cash, debit=900.0, line_deleted=True)       # a deleted line: not counted

    body = flask_app.test_client().get(
        '/api/reports/income_statement?start_date=2031-03-15&end_date=2031-03-15', headers=auth_headers).get_json()
    s = body['summary']
    assert s['net_revenue'] == pytest.approx(10000.0)
    assert s['cost_of_sales'] == pytest.approx(7000.0)
    assert s['gross_profit'] == pytest.approx(3000.0)
    assert s['operating_expenses'] == pytest.approx(1000.0)
    assert s['net_profit'] == pytest.approx(2000.0)
    assert s['gross_profit'] <= s['net_revenue']
    assert {d['account_name'] for d in body['cost_of_goods_sold']['details']} == {'مشتريات كسر اختبار'}
    assert {d['account_name'] for d in body['operating_expenses']['details']} == {'إيجار اختبار'}
    assert s['cost_basis'] == 'purchases' and 'المشتريات' in s['cost_basis_note']
