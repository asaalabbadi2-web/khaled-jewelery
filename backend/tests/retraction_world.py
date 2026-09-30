"""Real invoices for the retraction tests (UNPOST-001): made by the real creation path.

A scrap purchase paid in cash (3170's shape), the same unpaid, a sale on
credit -- posted at creation, or held for approval (a purchase above the live
price, a sale with a large discount). The holder has a custody safe, as in
production, so a scrap purchase's gold has somewhere to go.
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Customer, Employee, PaymentMethod, SafeBox, Settings, db

SHAPES = ('scrap_purchase_paid', 'scrap_purchase_unpaid', 'sale_on_credit')


@pytest.fixture
def unposting_allowed():
    row = Settings.query.first()
    if row is None:
        row = Settings()
        db.session.add(row)
    row.allow_unposting = True
    db.session.flush()


@pytest.fixture
def world():
    """A cash method, and a holder whose custody safe the scrap gold goes to -- as in production."""
    box = SafeBox(name=f'خزينة U0 {uuid.uuid4().hex[:6]}', safe_type='cash',
                  account_id=Account.query.get(15).id, is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(payment_type='cash', name=f'نقداً U0 {uuid.uuid4().hex[:6]}', commission_rate=0.0,
                       commission_timing='invoice', is_active=True, default_safe_box_id=box.id)
    gold_account = Account(account_number=f'79{uuid.uuid4().int % 10**6:06d}', name='عهدة U0', type='Asset')
    db.session.add_all([pm, gold_account])
    db.session.flush()
    gold_box = SafeBox(name=f'عهدة ذهب U0 {uuid.uuid4().hex[:6]}', safe_type='gold',
                       account_id=gold_account.id, is_active=True)
    db.session.add(gold_box)
    db.session.flush()
    holder = Employee.query.first()
    holder.gold_safe_box_id = gold_box.id
    db.session.flush()
    return {'pm': pm, 'customer': Customer.query.first(), 'holder': holder}


def _payload(world, shape, *, held):
    price = 100000.0 if held else 100.0
    if shape == 'sale_on_credit':
        # A sale is held for a large discount (the test world has no average
        # cost, so below-cost never fires): 20 % of 1,000 against a 10 % bar.
        price = 1000.0
        return {'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
                'employee_id': world['holder'].id, 'date': datetime.now().isoformat(),
                'total': price, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': 0.0, 'payments': [],
                'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': price, 'net': price,
                           'quantity': 1, 'wage': 0, 'selling_price': price,
                           'discount_amount': 200.0 if held else 0.0}]}
    paid = shape == 'scrap_purchase_paid'
    return {'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
            'transaction_type': 'buy', 'employee_id': world['holder'].id,
            'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
            'date': datetime.now().isoformat(), 'total': price, 'total_weight': 0.5, 'total_cost': price,
            'total_tax': 0.0, 'amount_paid': price if paid else 0.0,
            'payments': [{'payment_method_id': world['pm'].id, 'amount': price}] if paid else [],
            'items': [{'name': 'كسر', 'karat': 18, 'weight': 0.5, 'standing_weight': 0.5, 'stones_weight': 0.0,
                       'price': price, 'net': price, 'quantity': 1}]}


def _create(headers, world, shape, *, held):
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=_payload(world, shape, held=held))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    data = resp.get_json()
    assert bool(data['is_posted']) is (not held), f'{shape}: expected held={held}'
    return data
