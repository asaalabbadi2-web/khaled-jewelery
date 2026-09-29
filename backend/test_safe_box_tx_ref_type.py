"""Tests confirming that SafeBoxTransaction ref_type is set correctly.

Key invariant: when _append_safe_transactions_for_voucher processes a voucher
that was auto-generated from an invoice payment (identifiable by
voucher.notes containing "invoice_payment_id"), the resulting SafeBoxTransaction
rows must have ref_type='invoice_payment' — not 'voucher'.

This ensures the clearing settlement system (scheduler + pending-transactions
endpoint) can discover these transactions.
"""

import json
import pytest
from app import app as _app
from models import db, SafeBox, SafeBoxTransaction, Voucher, VoucherAccountLine, Account

@pytest.fixture()
def app():
    _app.config['TESTING'] = True
    _app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite://'
    with _app.app_context():
        db.create_all()
        yield _app
        db.session.rollback()
        db.drop_all()

@pytest.fixture()
def client(app):
    return app.test_client()

def _make_account(name, number, acc_type='asset'):
    a = Account(name=name, account_number=number, account_type=acc_type, type=acc_type)
    db.session.add(a)
    db.session.flush()
    return a


def test_invoice_payment_voucher_gets_invoice_payment_ref_type(app):
    """Voucher created from an invoice payment -> ref_type='invoice_payment'."""
    from routes import _append_safe_transactions_for_voucher

    with app.app_context():
        acc = _make_account('Clearing', '2100', 'asset')
        sb = SafeBox(name='Test Clearing', safe_type='clearing', account_id=acc.id, is_active=True)
        db.session.add(sb)
        db.session.flush()

        # Simulate a voucher auto-created from an invoice payment
        v = Voucher(
            voucher_number='V-TEST-001',
            voucher_type='receipt',
            reference_type='invoice',
            reference_id=str(1),
            notes=json.dumps({'invoice_payment_id': 42, 'payment_method_id': 1}),
            status='approved',
            created_by='test',
        )
        db.session.add(v)
        db.session.flush()

        db.session.add(VoucherAccountLine(
            voucher_id=v.id,
            account_id=acc.id,
            line_type='debit',
            amount_type='cash',
            amount=500.0,
        ))
        db.session.flush()

        txs = _append_safe_transactions_for_voucher(v, created_by='test')
        assert len(txs) == 1
        assert txs[0].ref_type == 'invoice_payment'
        assert txs[0].invoice_payment_id == 42
        assert txs[0].direction == 'in'
        assert txs[0].amount_cash == 500.0


def test_regular_voucher_keeps_voucher_ref_type(app):
    """A manual voucher (no invoice_payment_id) -> ref_type='voucher'."""
    from routes import _append_safe_transactions_for_voucher

    with app.app_context():
        acc = _make_account('Bank', '1100', 'asset')
        sb = SafeBox(name='Test Bank', safe_type='bank', account_id=acc.id, is_active=True)
        db.session.add(sb)
        db.session.flush()

        v = Voucher(
            voucher_number='V-TEST-002',
            voucher_type='receipt',
            status='approved',
            created_by='test',
        )
        db.session.add(v)
        db.session.flush()

        db.session.add(VoucherAccountLine(
            voucher_id=v.id,
            account_id=acc.id,
            line_type='debit',
            amount_type='cash',
            amount=200.0,
        ))
        db.session.flush()

        txs = _append_safe_transactions_for_voucher(v, created_by='test')
        assert len(txs) == 1
        assert txs[0].ref_type == 'voucher'
        assert txs[0].invoice_payment_id is None


def test_clearing_settlement_voucher_keeps_voucher_ref_type(app):
    """Clearing settlement voucher -> ref_type='voucher' (not invoice_payment)."""
    from routes import _append_safe_transactions_for_voucher

    with app.app_context():
        clearing_acc = _make_account('Clearing', '2100', 'asset')
        bank_acc = _make_account('Bank', '1100', 'asset')

        clearing_sb = SafeBox(name='Clearing SB', safe_type='clearing', account_id=clearing_acc.id, is_active=True)
        bank_sb = SafeBox(name='Bank SB', safe_type='bank', account_id=bank_acc.id, is_active=True)
        db.session.add_all([clearing_sb, bank_sb])
        db.session.flush()

        v = Voucher(
            voucher_number='V-SETTLE-001',
            voucher_type='adjustment',
            reference_type='clearing_settlement',
            notes='auto_settlement',
            status='approved',
            created_by='scheduler',
        )
        db.session.add(v)
        db.session.flush()

        # Credit clearing, debit bank
        db.session.add(VoucherAccountLine(
            voucher_id=v.id, account_id=clearing_acc.id,
            line_type='credit', amount_type='cash', amount=500.0,
        ))
        db.session.add(VoucherAccountLine(
            voucher_id=v.id, account_id=bank_acc.id,
            line_type='debit', amount_type='cash', amount=500.0,
        ))
        db.session.flush()

        txs = _append_safe_transactions_for_voucher(v, created_by='scheduler')
        assert len(txs) == 2
        for tx in txs:
            assert tx.ref_type == 'voucher', (
                f"Settlement voucher SafeBoxTx should be 'voucher', got '{tx.ref_type}'"
            )


def test_idempotency_guard_prevents_double_posting(app):
    """Second call to _append_safe_transactions_for_voucher returns [] for invoice_payment."""
    from routes import _append_safe_transactions_for_voucher

    with app.app_context():
        acc = _make_account('Clearing', '2100', 'asset')
        sb = SafeBox(name='Clearing', safe_type='clearing', account_id=acc.id, is_active=True)
        db.session.add(sb)
        db.session.flush()

        v = Voucher(
            voucher_number='V-TEST-IDEMPOTENT-001',
            voucher_type='receipt',
            reference_type='invoice',
            reference_id=str(1),
            notes=json.dumps({'invoice_payment_id': 99}),
            status='approved',
            created_by='test',
        )
        db.session.add(v)
        db.session.flush()

        db.session.add(VoucherAccountLine(
            voucher_id=v.id,
            account_id=acc.id,
            line_type='debit',
            amount_type='cash',
            amount=300.0,
        ))
        db.session.flush()

        txs1 = _append_safe_transactions_for_voucher(v, created_by='test')
        assert len(txs1) == 1
        assert txs1[0].ref_type == 'invoice_payment'

        # Second call must be idempotent
        txs2 = _append_safe_transactions_for_voucher(v, created_by='test')
        assert txs2 == []

        # Only 1 row in DB
        count = SafeBoxTransaction.query.filter_by(ref_id=v.id).count()
        assert count == 1


def test_invoice_payment_safe_box_tx_rejects_mismatched_voucher_notes(app):
    """Guard: invoice_payment tx pointing at a voucher must match voucher.notes invoice_payment_id."""
    with app.app_context():
        acc = _make_account('Clearing', '2100', 'asset')
        sb = SafeBox(name='Test Clearing', safe_type='clearing', account_id=acc.id, is_active=True)
        db.session.add(sb)
        db.session.flush()

        # Voucher says invoice_payment_id=42
        v = Voucher(
            voucher_number='V-TEST-MISMATCH-001',
            voucher_type='receipt',
            reference_type='invoice',
            reference_id=str(1),
            notes=json.dumps({'invoice_payment_id': 42, 'payment_method_id': 1}),
            status='approved',
            created_by='test',
        )
        db.session.add(v)
        db.session.flush()

        # Try to create a SafeBoxTransaction that claims invoice_payment_id=99 but ref_id points to voucher v.id.
        bad = SafeBoxTransaction(
            safe_box_id=sb.id,
            ref_type='invoice_payment',
            ref_id=v.id,
            invoice_payment_id=99,
            direction='in',
            amount_cash=100.0,
            created_by='test',
        )
        db.session.add(bad)

        with pytest.raises(Exception):
            db.session.flush()

        # Expected: flush failed, so session needs rollback before any further DB work.
        db.session.rollback()
