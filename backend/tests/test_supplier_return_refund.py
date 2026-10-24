"""A supplier return refunds in cash at most what it charges the supplier in cash (supplier return, one form).

Two forms made a supplier's return. The purchase screen in return mode posts
it as its purchase reversed: the supplier debited for the wages and their VAT,
the gold back by weight, no cash for the gold's value (RETURN-WAGE-1). The
general return form -- made for a customer, whose refund is cash -- asked a
payment method and an amount, proposed the original's total by weight (the
gold's value with its wages), and posted it as a receipt: cash debited and the
supplier credited, a payment never received and a debt to the supplier with
no cause. On the 24 Oct copy, half of purchase 3470 back made a receipt of
15,873.69 into the main cash, and left its wages (460.40) unreversed.

The owner (25 Oct 2026): one form -- the purchase screen's. The law here holds
whatever form sends it: a supplier return's cash refund cannot pass what it
charges the supplier in cash.

Run:
    python -m pytest tests/test_supplier_return_refund.py -v
"""
import uuid
from datetime import datetime

from app import app as flask_app
from models import Account, Invoice, InvoiceItem, PaymentMethod, SafeBox, db
from tests.test_wage_treatment_follows_the_setting import (  # noqa: F401 (fixtures)
    app, books, rollback_after_each, _vat, _create, _purchase, _settings,
)


def _cash_method():
    box = SafeBox(name=f'خزينة {uuid.uuid4().hex[:6]}', safe_type='cash',
                  account_id=Account.query.filter_by(account_number='1100000').first().id
                  if Account.query.filter_by(account_number='1100000').first() else Account.query.get(15).id,
                  is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(payment_type='cash', name=f'نقداً {uuid.uuid4().hex[:6]}', commission_rate=0.0,
                       is_active=True, default_safe_box_id=box.id)
    db.session.add(pm)
    db.session.flush()
    return pm


def _general_form(b, purchase, method, refund):
    """As the general return form sent it: items, a payment method and an amount."""
    item = InvoiceItem.query.filter_by(invoice_id=purchase['id']).first()
    return {
        'customer_id': None, 'supplier_id': b['supplier'].id, 'invoice_type': 'مرتجع شراء (مورد)',
        'original_invoice_id': purchase['id'], 'return_reason': 'تجربة', 'date': datetime.now().isoformat(),
        'total': refund, 'total_weight': 10.0, 'total_tax': 0.0, 'total_cost': refund, 'amount_paid': refund,
        'payments': [{'payment_method_id': method.id, 'amount': refund}],
        'items': [{'original_invoice_item_id': item.id, 'name': 'سلسال', 'karat': 21, 'weight': 10.0,
                   'wage': 20.0, 'quantity': 1, 'cost': 0, 'net': 0, 'tax': 0, 'tax_amount': 0, 'price': 0}],
    }


def test_a_refund_of_the_gold_s_value_is_refused_and_nothing_is_written(auth_headers, books):
    _settings('inventory')
    purchase = _create(auth_headers, _purchase(books))
    before = Invoice.query.count()
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers,
                                        json=_general_form(books, purchase, _cash_method(), 3905.0))
    assert resp.status_code == 400, resp.get_json()
    body = resp.get_json()
    assert body['error'] == 'supplier_return_refund_exceeds'
    assert body['allowed'] == 0.0, 'the general form sent no wages: it charges the supplier nothing in cash'
    assert Invoice.query.count() == before


def test_a_cash_refund_within_the_wages_and_their_vat_stands(auth_headers, books):
    """The purchase screen's partial settlement: the supplier pays back in
    cash what the return charges them -- the wages and their VAT."""
    _settings('inventory')
    purchase = _create(auth_headers, _purchase(books))
    item = InvoiceItem.query.filter_by(invoice_id=purchase['id']).first()
    method = _cash_method()
    ret = _create(auth_headers, {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': books['supplier'].id,
        'original_invoice_id': purchase['id'], 'gold_type': 'new', 'date': datetime.now().isoformat(),
        'total': 230.0, 'total_tax': 30.0, 'gold_subtotal': 3675.0, 'wage_subtotal': 200.0,
        'wage_tax_total': 30.0, 'gold_tax_total': 0.0, 'vat_applied': True,
        'manufacturing_wage_cash': 200.0, 'settlement_method': 'partial',
        'payments': [{'payment_method_id': method.id, 'amount': 230.0}], 'amount_paid': 230.0,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1,
                   'manufacturing_wage_per_gram': 20.0, 'original_invoice_item_id': item.id}],
    })
    assert ret['id']


def test_a_return_on_credit_refunds_nothing_and_stands(auth_headers, books):
    _settings('inventory')
    purchase = _create(auth_headers, _purchase(books))
    item = InvoiceItem.query.filter_by(invoice_id=purchase['id']).first()
    ret = _create(auth_headers, {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': books['supplier'].id,
        'original_invoice_id': purchase['id'], 'gold_type': 'new', 'date': datetime.now().isoformat(),
        'total': 230.0, 'total_tax': 30.0, 'wage_subtotal': 200.0, 'wage_tax_total': 30.0,
        'gold_tax_total': 0.0, 'vat_applied': True, 'manufacturing_wage_cash': 200.0,
        'settlement_method': 'credit', 'amount_paid': 0.0,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1,
                   'manufacturing_wage_per_gram': 20.0, 'original_invoice_item_id': item.id}],
    })
    assert ret['id']
