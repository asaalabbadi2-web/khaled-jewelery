"""The clearing auto-settlement: a bulk settlement carries its fee.

Brought in from the root (TEST-003): its safe-box rows named invoice payments
20001-20003 that did not exist -- on PostgreSQL the foreign key refuses them.
Real payments on a posted invoice now, behind the fence. Its second test
counted the due rows after the last settlement with a function ADR-037 replaced
(a settlement is dated by when its money reaches the bank, one schedule
reading); tests/test_settlement_schedule*.py and test_settlement_dated_on_deposit
pin that now.
"""
import uuid
from datetime import datetime

import pytest

import routes
from app import app
from clearing_settlement_scheduler import ClearingSettlementScheduler
from models import Account, Invoice, InvoicePayment, PaymentMethod, SafeBox, SafeBoxTransaction, db


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _payment(method, amount):
    """A payment that stands: on a posted invoice, its method the card's."""
    inv = Invoice(invoice_type='بيع', invoice_type_id=uuid.uuid4().int % 10**8, date=datetime.now(),
                  total=amount, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    ip = InvoicePayment(invoice_id=inv.id, payment_method_id=method.id, amount=amount, net_amount=amount)
    db.session.add(ip)
    db.session.flush()
    return ip.id


def _create_safe_box(name: str, safe_type: str, account_number: str) -> SafeBox:
    account = Account(
        account_number=f'{account_number}{uuid.uuid4().int % 10**6:06d}',
        name=f'حساب {name}',
        type='Asset',
        balance_cash=0.0,
    )
    db.session.add(account)
    db.session.flush()

    safe_box = SafeBox(
        name=name,
        safe_type=safe_type,
        account_id=account.id,
        is_active=True,
    )
    db.session.add(safe_box)
    db.session.flush()
    return safe_box


def test_auto_settlement_bulk_supports_settlement_fee(monkeypatch):
    captured = {}

    with app.app_context():
        clearing_safe = _create_safe_box('مستحقات تلقائية', 'clearing', '9201')
        bank_safe = _create_safe_box('بنك تلقائي', 'bank', '9202')

        payment_method = PaymentMethod(
            payment_type='receivable',
            name='بطاقة اختبار تلقائية',
            commission_rate=2.5,
            commission_fixed_amount=0.0,
            auto_settlement_enabled=True,
            settlement_schedule_type='days',
            settlement_days=0,
            settlement_bank_safe_box_id=bank_safe.id,
            default_safe_box_id=clearing_safe.id,
            settlement_mode='bulk',
            is_active=True,
        )
        db.session.add(payment_method)
        db.session.flush()

        paid = _payment(payment_method, 100.0)
        db.session.add(
            SafeBoxTransaction(
                safe_box_id=clearing_safe.id,
                ref_type='invoice_payment',
                ref_id=paid,
                invoice_payment_id=paid,
                direction='in',
                amount_cash=100.0,
                created_at=datetime.now(),
            )
        )
        db.session.commit()

        def fake_create_clearing_settlement_voucher(**kwargs):
            captured.update(kwargs)
            return {'success': True, 'voucher': {'voucher_number': 'AUTO-SETTLE-1'}}

        monkeypatch.setattr(routes, '_create_clearing_settlement_voucher', fake_create_clearing_settlement_voucher)
        monkeypatch.setattr(ClearingSettlementScheduler, '_live_cash_balance_for_safe_box', lambda self, safe_box: 100.0)
        monkeypatch.setattr(db.session, 'commit', lambda: None)
        monkeypatch.setattr(db.session, 'rollback', lambda: None)

        scheduler = ClearingSettlementScheduler(app)
        scheduler.process_due_settlements()

    assert captured['gross_amount'] == 100.0
    assert captured['fee_amount'] == 2.5
    assert captured['fee_account_id'] is None
    # The batch it closes and the day its money reaches the bank (ADR-037, d6924191).
    assert captured['notes'].startswith('auto_settlement:batch=')
    assert ';deposit=' in captured['notes']
