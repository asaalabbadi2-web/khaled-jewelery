"""The income statement: riyals by the tree, grams by the gram profit's five layers -- one definition (REPORTS ت2-2, ADR-083).

The owner, 4 Nov 2026: «ربح الجرام هو طبقات ربح الجرام الخمس» and
«اوافق على التوصية كما هي». The constitution's WPROFIT-001: the gram profit
(the weight close's engine, ADR-048) and the weight income statement (the
tree's weight accounts 74/75, where every gram bought from a customer is a
weight gain) stood on two bases -- on the 2 Nov copy about 2,600 g against
20,809 g for the year. Now one definition: the statement's grams are the
gram profit's five layers, read from the one engine; the law -- its net in
grams is the gram profit report's net for the same period. The tree's
weight income statement goes.

Run:
    python -m pytest tests/test_report_income_statement.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from tests.test_dashboard_expenses_are_operating import _account, _child

DAY = dt.datetime(2031, 4, 15)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _post(account, other, *, debit=0.0, credit=0.0):
    je = JournalEntry(entry_number=f'JE-S-{uuid.uuid4().hex[:8]}', date=DAY, description='اختبار',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id, cash_debit=debit, cash_credit=credit,
                         description='اختبار'),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=credit, cash_credit=debit,
                         description='اختبار'),
    ])
    db.session.flush()


@pytest.fixture
def books():
    revenue_root = _account('4', 'الإيرادات', type_='Revenue')
    sales = _child(revenue_root, 'مبيعات قائمة')
    expenses = _account('5', 'المصروفات')
    cost = _child(_account('51', 'تكلفة المبيعات', expenses), 'تكلفة قائمة')
    rent = _child(_account('52', 'مصاريف تشغيلية', expenses), 'إيجار قائمة')
    cash = Account(account_number=f'9{uuid.uuid4().hex[:6]}', name='صندوق', type='Asset')
    db.session.add(cash)
    db.session.flush()
    _post(sales, cash, credit=10000.0)
    _post(cost, cash, debit=7000.0)
    _post(rent, cash, debit=1000.0)
    return {'sales': sales, 'cost': cost, 'rent': rent}


def _statement():
    from services.reports.income_statement import income_statement
    return income_statement(start=DAY.date(), end=DAY.date(), now=dt.datetime(2031, 5, 1))


def _row(report, key):
    return next(r for r in report.rows if r.get('key') == key)


def test_its_riyals_are_the_tree_s(books):
    report = _statement()
    assert _row(report, 'revenue_total')['cash'] == pytest.approx(10000.0)
    assert _row(report, 'cost_of_sales_total')['cash'] == pytest.approx(7000.0)
    assert _row(report, 'gross_profit')['cash'] == pytest.approx(3000.0)
    assert _row(report, 'operating_total')['cash'] == pytest.approx(1000.0)
    assert _row(report, 'net_profit')['cash'] == pytest.approx(2000.0)
    sales = next(r for r in report.rows if r.get('account_id') == books['sales'].id)
    assert sales['drill'] == {'kind': 'account', 'id': books['sales'].id}


def test_its_grams_are_the_gram_profit_s_five_layers(books):
    from services.weight_position import performance
    report = _statement()
    engine = performance(DAY.date(), DAY.date())
    layers = {r['key']: r['weight'] for r in report.rows if r.get('key', '').startswith('layer_')}
    assert set(layers) == {'layer_trading', 'layer_revenue', 'layer_expense_direct', 'layer_expense_cash',
                           'layer_waiting'}
    assert _row(report, 'gram_profit')['weight'] == pytest.approx(engine['weight_profit'], abs=0.001)
    assert sum(layers.values()) == pytest.approx(engine['weight_profit'], abs=0.002)


def test_the_law_its_grams_are_the_gram_profit_report_s(auth_headers, books):
    """One definition, both read it: the statement's net in grams is the gram
    profit report's for the same period (WPROFIT-001's parity law)."""
    g.pop('current_user', None)
    client = flask_app.test_client()
    period = 'start_date=2031-04-15&end_date=2031-04-15'
    gram = client.get(f'/api/reports/gram_profit?{period}', headers=auth_headers).get_json()
    g.pop('current_user', None)
    body = client.get(f'/api/reports/income_statement?{period}', headers=auth_headers).get_json()
    net = next(r for r in body['rows'] if r.get('key') == 'gram_profit')['weight']
    assert net == pytest.approx(gram['net_profit_weight'], abs=0.001)
    assert body['id'] == 'income_statement' and body['basis'] == 'posted_entries'
    assert body['summary']['net_profit'] == pytest.approx(2000.0), 'the old keys, until the screen moves'


def test_the_tree_s_weight_income_statement_is_gone(auth_headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/reports/income-statement/gold?start_date=2031-04-01&end_date=2031-04-30',
                                       headers=auth_headers)
    assert resp.status_code == 404
