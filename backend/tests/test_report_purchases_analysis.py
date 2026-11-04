"""Purchases analysis: from the documents, in riyals as the books keep them and in grams (REPORTS ت4-4أ, ADR-083).

The owner, 4 Nov 2026: a purchase's value is what keeps the income
statement sound -- the books' riyals. A customer's or an office's purchase
is its price before VAT (512 or 511, by the purchase roles); a supplier's is
its wage (1320, the wage inventory) -- its gold is a debt in grams, never
riyals; a return takes its own off (513, and the wage back). Its grams in the
main karat, beside. On the 2 Nov copy October agrees to the halala: 512
1,053,167.59 (customers 493,147.00 + offices 560,020.58), 513 -11,250.00,
1320 from the purchases 26,693.98 (wages 27,652.94 less a return's 958.96).
So the report checks it of itself, as the sales analysis does.

Run:
    python -m pytest tests/test_report_purchases_analysis.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, SafeBox, Settings, Supplier, db
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_weight_position import _post

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture(autouse=True)
def _vat(vat_mapped):
    yield


@pytest.fixture
def supplier():
    """As production (tests/test_supplier_purchase_effect.py): wage inventory
    1320, VAT on purchases 1400, the display stock's weight on a memo account."""
    from party_account_service import ensure_supplier_accounts
    for number, name in (('1320', 'مخزون أجور المصنعية'), ('1400', 'ضريبة مدفوعة على المشتريات')):
        if not Account.query.filter_by(account_number=number).first():
            db.session.add(Account(account_number=number, name=name, type='Asset'))
    stock = Account.query.filter_by(account_number='1300').one()
    memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}', name='مخزون معروض وزني', type='Asset',
                   tracks_weight=True)
    db.session.add(memo)
    db.session.flush()
    stock.memo_account_id = memo.id
    db.session.add(SafeBox(name=f'المعروض {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=memo.id,
                           is_active=True))
    supplier = Supplier(supplier_code=f'SUP-{uuid.uuid4().hex[:6]}', name=f'مورد تحليل {uuid.uuid4().hex[:6]}',
                        default_wage_type='cash')
    db.session.add(supplier)
    row = Settings.query.first() or Settings()
    row.tax_enabled, row.tax_rate, row.auto_post_invoices = True, 0.15, True
    row.manufacturing_wage_mode = 'inventory'
    db.session.add(row)
    db.session.flush()
    ensure_supplier_accounts(supplier)
    db.session.flush()
    from accounting.mappings import _ACCOUNT_NUMBER_CACHE
    for n in ('1320', '1400'):
        _ACCOUNT_NUMBER_CACHE.pop(n, None)
    return supplier


def _scrap(headers, world, when, price, grams):
    return _post(headers, {
        'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': world['holder'].id,
        'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
        'date': when.isoformat(), 'total': price, 'total_weight': grams, 'total_cost': price,
        'total_tax': 0.0, 'amount_paid': price, 'payments': [{'payment_method_id': world['pm'].id, 'amount': price}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': grams, 'standing_weight': grams, 'stones_weight': 0.0,
                   'price': price, 'net': price, 'quantity': 1}]})


def _supplied(headers, supplier, when, wage, grams):
    gold = 367.5 * grams
    return _post(headers, {
        'invoice_type': 'شراء', 'supplier_id': supplier.id, 'gold_type': 'new', 'date': when.isoformat(),
        'settlement_method': 'credit', 'amount_paid': 0.0, 'total': gold + wage * 1.15, 'total_tax': wage * 0.15,
        'gold_subtotal': gold, 'wage_subtotal': wage, 'wage_tax_total': wage * 0.15, 'gold_tax_total': 0.0,
        'vat_applied': True, 'items': [],
        'karat_lines': [{'karat': 21, 'weight_grams': grams, 'gold_value_cash': gold,
                         'manufacturing_wage_cash': wage, 'gold_tax': 0.0, 'wage_tax': wage * 0.15}]})


@pytest.fixture
def bought(auth_headers, world, supplier):
    return {
        # below the live price: posted, not held for approval
        'scrap_a': _scrap(auth_headers, world, D(2042, 3, 4, 10), 200.0, 2.0),
        'scrap_b': _scrap(auth_headers, world, D(2042, 3, 20, 10), 50.0, 0.5),
        'supplied': _supplied(auth_headers, supplier, D(2042, 3, 10, 10), 200.0, 10.0),
        'april': _scrap(auth_headers, world, D(2042, 4, 2, 10), 100.0, 1.0),
        'supplier': supplier, 'customer': world['customer'],
    }


def _analysis(**kw):
    from services.reports.purchases_analysis import purchases_analysis
    return purchases_analysis(now=D(2042, 5, 1), start=dt.date(2042, 3, 1), end=dt.date(2042, 3, 31), **kw)


def _rows(report):
    return {r['group']: r for r in report.rows}


def test_by_kind_the_books_riyals_and_the_grams(bought):
    report = _analysis(by='kind')
    rows = _rows(report)
    assert rows['من العملاء']['value'] == pytest.approx(250.0) and rows['من العملاء']['invoices'] == 2
    assert rows['من العملاء']['weight'] == pytest.approx(2.5)
    assert rows['من الموردين']['value'] == pytest.approx(200.0), 'its wage: the gold is a debt in grams'
    assert rows['من الموردين']['weight'] == pytest.approx(10.0)
    assert report.totals['value'] == pytest.approx(450.0)
    assert report.basis == 'documents'


def test_it_agrees_with_the_books_and_says_when_it_does_not(bought):
    from models import Invoice
    assert {c.key: c.ok for c in _analysis(by='kind').checks} == {'books_agree': True}
    db.session.get(Invoice, bought['scrap_b']).total = 80.0           # changed after it was posted
    db.session.flush()
    assert {c.key: c.ok for c in _analysis(by='kind').checks} == {'books_agree': False}


def test_by_party_each_opens_its_statement(bought):
    rows = _rows(_analysis(by='party'))
    supplier = rows[bought['supplier'].name]
    assert supplier['drill'] == {'kind': 'supplier', 'id': bought['supplier'].id}
    assert supplier['last'] == '2042-03-10'
    customer = rows[bought['customer'].name]
    assert customer['drill'] == {'kind': 'customer', 'id': bought['customer'].id}
    assert customer['value'] == pytest.approx(250.0)


def test_by_month_with_its_chart_and_compared(bought):
    from services.reports.purchases_analysis import purchases_analysis
    report = purchases_analysis(now=D(2042, 5, 1), start=dt.date(2042, 3, 1), end=dt.date(2042, 4, 30), by='month')
    rows = _rows(report)
    assert rows['2042-03']['value'] == pytest.approx(450.0) and rows['2042-04']['value'] == pytest.approx(100.0)
    assert report.to_dict()['chart'] == {'x': 'group', 'y': 'value'}
    april = purchases_analysis(now=D(2042, 5, 1), start=dt.date(2042, 4, 1), end=dt.date(2042, 4, 30),
                               by='kind', compare=True)
    assert _rows(april)['من العملاء']['prev_value'] == pytest.approx(250.0), 'March, the month before'


def test_by_karat_the_grams_of_each(bought):
    rows = _rows(_analysis(by='karat'))
    assert rows['عيار 21']['weight'] == pytest.approx(12.5)
    assert rows['عيار 21']['value'] == pytest.approx(450.0)


def test_the_route_answers_the_contract(auth_headers, bought):
    g.pop('current_user', None)
    resp = flask_app.test_client().get(
        '/api/reports/purchases-analysis?start_date=2042-03-01&end_date=2042-03-31&by=kind', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['id'] == 'purchases_analysis' and body['basis'] == 'documents'
    g.pop('current_user', None)
    bad = flask_app.test_client().get('/api/reports/purchases-analysis?by=nothing', headers=auth_headers)
    assert bad.status_code == 400 and bad.get_json()['error'] == 'invalid_by'
