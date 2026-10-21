from datetime import datetime

from app import app
from models import db, Account, Customer, Employee, Invoice, PaymentMethod, SafeBox

import pytest

@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



def _ensure_cash_payment_method() -> PaymentMethod:
    safe_box = SafeBox.query.filter_by(name='خزينة اختبار نقدية').first()
    if not safe_box:
        cash_account = Account.query.get(15)
        safe_box = SafeBox(
            name='خزينة اختبار نقدية',
            safe_type='cash',
            account_id=cash_account.id,
            is_active=True,
            is_default=True,
        )
        db.session.add(safe_box)
        db.session.flush()

    payment_method = PaymentMethod.query.filter_by(name='نقداً - اختبار').first()
    if not payment_method:
        payment_method = PaymentMethod(
            payment_type='cash',
            name='نقداً - اختبار',
            commission_rate=0.0,
            is_active=True,
            default_safe_box_id=safe_box.id,
        )
        db.session.add(payment_method)
        db.session.flush()

    db.session.commit()
    return payment_method


def test_customer_scrap_purchase_above_live_price_requires_approval(auth_headers):
    with app.app_context():
        customer = Customer.query.first()
        employee = Employee.query.first()
        payment_method = _ensure_cash_payment_method()

        assert customer is not None
        assert employee is not None

        payload = {
            'customer_id': customer.id,
            'invoice_type': 'شراء من عميل',
            'gold_type': 'scrap',
            'transaction_type': 'buy',
            'employee_id': employee.id,
            'scrap_holder_employee_id': employee.id,
            'safe_box_id': payment_method.default_safe_box_id,
            'date': datetime.now().isoformat(),
            'total': 100.0,
            'total_weight': 0.2,
            'total_cost': 100.0,
            'total_tax': 0.0,
            'amount_paid': 100.0,
            'payments': [
                {
                    'payment_method_id': payment_method.id,
                    'amount': 100.0,
                }
            ],
            'items': [
                {
                    'name': 'كسر اختبار فوق المباشر',
                    'karat': 21,
                    'weight': 0.2,
                    'standing_weight': 0.2,
                    'stones_weight': 0.0,
                    'price': 100.0,
                    'net': 100.0,
                    'quantity': 1,
                }
            ],
            'notes': 'اختبار اعتماد الشراء أعلى من السعر المباشر',
        }

    with app.test_client() as client:
        response = client.post('/api/invoices', json=payload, headers=auth_headers)

    assert response.status_code == 201
    data = response.get_json()

    assert data.get('approval_required') is True
    assert 'above_live_price' in (data.get('approval_reasons') or [])
    assert data.get('is_posted') is False

    above_live_price = data.get('above_live_price') or {}
    items = above_live_price.get('items') or []
    assert items
    assert items[0]['paid_per_gram'] > items[0]['max_allowed_per_gram']

    with app.app_context():
        invoice = Invoice.query.get(data['id'])
        assert invoice is not None
        assert invoice.invoice_type == 'شراء من عميل'
        assert invoice.is_posted is False