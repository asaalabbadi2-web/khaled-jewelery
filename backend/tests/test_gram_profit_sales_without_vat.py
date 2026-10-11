"""The gram profit's sales leave the VAT out (the owner, 11 Oct 2026).

«إن كانت الضريبة مفعّلة على الفاتورة فهي لا تُحسب كإيراد بالأصل لذا يتجاهلها،
والعكس صحيح». The report summed each sale's total -- VAT and all: on the 10
Oct copy January to May's sales carried 533,791 of VAT into the margin per
gram. The VAT a sale carries is what its posted entry credits to the sales
VAT account -- not the invoice's total_tax, which reads 15/115 of the whole
total and disagrees with the posting on 91 invoices (January-April 2026).

Run:
    python -m pytest tests/test_gram_profit_sales_without_vat.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from accounting.mappings import get_account_id_for_mapping
from models import Account, AccountingMapping, Invoice, JournalEntry, JournalEntryLine, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(tag, kind):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7}', name=tag, type=kind)
    db.session.add(a)
    db.session.flush()
    return a


def _vat_account():
    found = get_account_id_for_mapping('بيع', 'vat_payable')
    if found:
        return db.session.get(Account, found)
    vat = _account('ضريبة مبيعات اختبار', 'Liability')
    db.session.add(AccountingMapping(operation_type='بيع', account_type='vat_payable', account_id=vat.id, is_active=True))
    db.session.flush()
    return vat


def _sale(total, vat, revenue, receivable, vat_account, kind='بيع'):
    inv = Invoice(invoice_type_id=uuid.uuid4().int % 900000 + 1, invoice_type=kind, date=datetime(2033, 6, 10, 10),
                  total=total, total_weight=1.0, total_tax=round(total * 15 / 115, 2), status='paid',
                  amount_paid=total, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    je = JournalEntry(entry_number=f'JE-V-{uuid.uuid4().hex[:8]}', date=inv.date, description='بيع',
                      entry_type='عادي', reference_type='invoice', reference_id=inv.id,
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    sign = 1 if kind == 'بيع' else -1
    lines = [(receivable, total * sign), (revenue, -(total - vat) * sign)]
    if vat:
        lines.append((vat_account, -vat * sign))
    for account, amount in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='بيع',
                                        cash_debit=max(amount, 0), cash_credit=max(-amount, 0)))
    db.session.flush()


def test_a_sales_vat_is_not_revenue_and_a_sale_without_it_is_all_revenue(auth_headers):
    vat = _vat_account()
    revenue, receivable = _account('إيراد اختبار', 'Revenue'), _account('عميل اختبار', 'Asset')
    _sale(3300.0, 215.22, revenue, receivable, vat)       # VAT on the invoice: the posting's, not 15/115
    _sale(2000.0, 0.0, revenue, receivable, vat)          # no VAT: the total is the revenue
    _sale(1150.0, 150.0, revenue, receivable, vat, kind='مرتجع بيع')   # a return gives its VAT back
    # April 2026's returns gave theirs back on 2210, the mapping's fallback number
    # before 2300 was mapped: still the sales VAT.
    fallback = Account.query.filter_by(account_number='2210').first()
    if fallback is None:
        fallback = Account(account_number='2210', name='ضريبة القيمة المضافة المستحقة', type='Liability')
        db.session.add(fallback)
        db.session.flush()
    _sale(575.0, 75.0, revenue, receivable, fallback, kind='مرتجع بيع')

    body = flask_app.test_client().get('/api/reports/gram_profit?start_date=2033-06-01&end_date=2033-06-30',
                                       headers=auth_headers).get_json()

    assert body['total_sales_cash'] == pytest.approx(3084.78 + 2000.0 - 1000.0 - 500.0)

