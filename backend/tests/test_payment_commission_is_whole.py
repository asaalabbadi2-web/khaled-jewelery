"""A payment's commission is all its method deducts: its rate and its fixed amount (COMMISSION-3).

The owner, 29 Oct 2026: the invoice «لا تحسب المبلغ الثابت لكل عملية، أي أنها
لا تحسب كامل الاستقطاعات المحفوظة في إعدادات وسيلة الدفع». The settlement took
the rate and the fixed amount a transaction (settlement_fee); the invoice took
what its screen sent -- the rate alone, in five screens' own copies. On the 27
Oct copy: تابي, 6.99 % and 1.5 a transaction, two payments in October, 3.00
short. One computation now (accounting/payment_commission.py): the invoice's
estimate and the settlement's are the same; an invoice takes it from its
method, not from its screen. Its VAT is the commission's, and comes off no
profit (the owner: «الضريبة لا تطرح من ربح الفاتورة»).

Run:
    python -m pytest tests/test_payment_commission_is_whole.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import Invoice, InvoicePayment, PaymentMethod, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _tabby(**kw):
    pm = PaymentMethod(payment_type='tabby', name=f'تابي {uuid.uuid4().hex[:6]}', commission_rate=6.99,
                       commission_fixed_amount=1.5, is_active=True, **kw)
    db.session.add(pm)
    db.session.flush()
    return pm


def test_a_payment_s_commission_is_its_rate_and_its_fixed_amount(app):
    from accounting.payment_commission import payment_commission
    from clearing_settlement_scheduler import settlement_fee
    pm = _tabby()
    fee = payment_commission(pm, 1000.0)
    assert fee['commission_amount'] == pytest.approx(69.90 + 1.50)
    assert fee['net_amount'] == pytest.approx(1000.0 - fee['commission_amount'] - fee['commission_vat'])
    assert settlement_fee(pm, 1000.0, 1) == pytest.approx(fee['commission_amount']), 'one formula'
    assert payment_commission(pm, 0.0)['commission_amount'] == 0.0, 'nothing paid, nothing deducted'


def test_a_sale_takes_its_methods_whole_commission_whatever_its_screen_sent(app, auth_headers, world):
    """The screen sends the rate's 69.90; the sale keeps 71.40, and its cash
    profit is less by the commission, not its VAT."""
    from flask import g
    pm = _tabby(default_safe_box_id=world['pm'].default_safe_box_id)
    sale = {'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': world['holder'].id, 'date': datetime.now().isoformat(),
            'total': 1000.0, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': 1000.0,
            'payments': [{'payment_method_id': pm.id, 'amount': 1000.0,
                          'commission_amount': 69.90, 'commission_vat': 10.49}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]}
    g.pop('current_user', None)
    resp = app.test_client().post('/api/invoices', headers=auth_headers, json=sale)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    invoice = db.session.get(Invoice, resp.get_json()['id'])
    (payment,) = InvoicePayment.query.filter_by(invoice_id=invoice.id).all()
    assert payment.commission_amount == pytest.approx(71.40)
    assert payment.net_amount == pytest.approx(1000.0 - 71.40 - payment.commission_vat)
    assert invoice.commission_amount == pytest.approx(71.40)
    assert invoice.profit_cash == pytest.approx(1000.0 - (invoice.total_cost or 0.0) - 71.40, abs=0.01)
