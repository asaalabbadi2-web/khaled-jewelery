import json

import pytest
from app import app as _app
from models import (
    Account,
    JournalEntry,
    JournalEntryLine,
    SafeBox,
    SafeBoxTransaction,
    Voucher,
    VoucherAccountLine,
    db,
)


@pytest.fixture(scope='module')
def app():
    _app.config['TESTING'] = True
    with _app.app_context():
        yield _app


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """TEST-003: brought in from the root. Its fixture set a SQLite URI the app
    never read and ran db.create_all()/db.drop_all() on the run's database; on
    SQLite no foreign key held it to a payment that existed (it named 123)."""
    yield


def _payment():
    from datetime import datetime
    import uuid
    from models import Invoice, InvoicePayment, PaymentMethod
    pm = PaymentMethod.query.filter_by(payment_type='cash').first()
    if pm is None:
        pm = PaymentMethod(name='نقدي اختبار', payment_type='cash', is_active=True)
        db.session.add(pm)
        db.session.flush()
    inv = Invoice(invoice_type='شراء', invoice_type_id=uuid.uuid4().int % 10**8, date=datetime(2026, 10, 1),
                  total=150000.0)
    db.session.add(inv)
    db.session.flush()
    ip = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=150000.0, net_amount=150000.0)
    db.session.add(ip)
    db.session.flush()
    return ip.id, pm.id


def _make_account(name: str, number: str, acc_type: str = 'asset') -> Account:
    import uuid
    number = f'{number}{uuid.uuid4().int % 10**6:06d}'
    acc = Account(name=name, account_number=number, account_type=acc_type, type=acc_type)
    db.session.add(acc)
    db.session.flush()
    return acc


def test_append_safe_transactions_prefers_journal_entry_lines(app):
    """Regression guard:

    Even if VoucherAccountLine uses a non-safe account (drift), we must still create
    SafeBoxTransaction rows based on the linked JournalEntry lines (source of truth).
    """

    from routes import _append_safe_transactions_for_voucher

    with app.app_context():
        ip_id, pm_id = _payment()
        safe_acc = _make_account('Cash Safe Account', '1000', 'asset')
        other_cash = _make_account('Other Cash Account', '1001', 'asset')

        safe = SafeBox(name='Main Safe', safe_type='cash', account_id=safe_acc.id, is_active=True)
        db.session.add(safe)
        db.session.flush()

        voucher = Voucher(
            voucher_number='P-TEST-00001',
            voucher_type='payment',
            date=None,
            description='Test payment',
            created_by='test',
            status='approved',
            notes=json.dumps({'invoice_payment_id': ip_id, 'payment_method_id': pm_id}),
        )
        db.session.add(voucher)
        db.session.flush()

        # Voucher lines drift: use a non-safe account.
        db.session.add(
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=other_cash.id,
                line_type='credit',
                amount_type='cash',
                amount=150000.0,
                description='Drifted line',
            )
        )
        db.session.flush()

        je = JournalEntry(
            entry_number='JE-TEST-00001',
            date=None,
            description='Posted from voucher',
            reference_type='voucher',
            reference_id=voucher.id,
            created_by='test',
        )
        if hasattr(je, 'is_posted'):
            je.is_posted = True
        db.session.add(je)
        db.session.flush()

        # Actual posting hits the SafeBox account.
        db.session.add(
            JournalEntryLine(
                journal_entry_id=je.id,
                account_id=safe_acc.id,
                cash_debit=0.0,
                cash_credit=150000.0,
            )
        )
        db.session.flush()

        voucher.journal_entry_id = je.id
        db.session.add(voucher)
        db.session.flush()

        created = _append_safe_transactions_for_voucher(voucher, created_by='test')
        db.session.flush()

        assert len(created) == 1
        tx = created[0]
        assert tx.safe_box_id == safe.id
        assert tx.direction == 'out'
        assert float(tx.amount_cash or 0.0) == 150000.0
        assert tx.ref_type == 'invoice_payment'
        assert int(tx.invoice_payment_id) == ip_id

        # Idempotent.
        created2 = _append_safe_transactions_for_voucher(voucher, created_by='test')
        db.session.flush()
        assert created2 == []
        assert SafeBoxTransaction.query.filter_by(ref_id=voucher.id).count() == 1
