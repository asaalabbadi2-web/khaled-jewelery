from datetime import datetime

import routes
from app import app
from clearing_settlement_scheduler import ClearingSettlementScheduler
from models import Account, PaymentMethod, SafeBox, SafeBoxTransaction, db


def _create_safe_box(name: str, safe_type: str, account_number: str) -> SafeBox:
    account = Account(
        account_number=account_number,
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

        db.session.add(
            SafeBoxTransaction(
                safe_box_id=clearing_safe.id,
                ref_type='invoice_payment',
                ref_id=20001,
                invoice_payment_id=20001,
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
    assert captured['notes'] == 'auto_settlement'


def test_bulk_due_transaction_count_uses_latest_settlement_boundary():
    with app.app_context():
        clearing_safe = _create_safe_box('مستحقات عداد', 'clearing', '9203')
        bank_safe = _create_safe_box('بنك عداد', 'bank', '9204')
        db.session.commit()

        scheduler = ClearingSettlementScheduler(app)
        now = datetime.now()

        db.session.add(
            SafeBoxTransaction(
                safe_box_id=clearing_safe.id,
                ref_type='invoice_payment',
                ref_id=20002,
                invoice_payment_id=20002,
                direction='in',
                amount_cash=50.0,
                created_at=now,
            )
        )
        db.session.add(
            SafeBoxTransaction(
                safe_box_id=clearing_safe.id,
                ref_type='invoice_payment',
                ref_id=20003,
                invoice_payment_id=20003,
                direction='in',
                amount_cash=75.0,
                created_at=now,
            )
        )
        db.session.commit()

        count = scheduler._count_bulk_due_transactions(clearing_safe.id, now)

    assert count == 2