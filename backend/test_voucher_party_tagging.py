from datetime import datetime

from app import app
from models import Account, JournalEntryLine, Supplier, Voucher, VoucherAccountLine, db
from routes import approve_voucher, generate_voucher_number



def _sign_in_as_system_admin():
    """The route is called directly; since ADR-036 it asks who calls (vouchers.edit / vouchers.approve)."""
    from flask import g
    from models import AppUser
    g.current_user = AppUser.query.filter_by(role='system_admin').first() or AppUser(
        username='pytest-admin', role='system_admin', is_active=True, password_hash='x')

def test_voucher_approval_tags_supplier_on_journal_lines():
    with app.app_context():
        supplier = Supplier.query.get(1)
        assert supplier is not None

        # Ensure a payable (liability) account to post against.
        supplier_account = Account.query.filter_by(account_number="2100001").first()
        if not supplier_account:
            supplier_account = Account(
                account_number="2100001",
                name="مورد اختبار - حساب",
                type="Liability",
                transaction_type="both",
                tracks_weight=False,
            )
            db.session.add(supplier_account)
            db.session.flush()

        supplier.account_id = supplier_account.id

        # Gold safe/inventory account (not necessarily a SafeBox in tests).
        gold_account = Account.query.filter_by(account_number="1300").first()
        if not gold_account:
            gold_account = Account(
                account_number="1300",
                name="خزنة ذهب اختبار",
                type="Asset",
                transaction_type="gold",
                tracks_weight=True,
            )
            db.session.add(gold_account)
            db.session.flush()

        cash_account = Account.query.filter_by(account_number="15").first()
        assert cash_account is not None

        voucher = Voucher(
            voucher_number=generate_voucher_number("payment"),
            voucher_type="payment",
            date=datetime.now(),
            party_type="supplier",
            supplier_id=supplier.id,
            amount_cash=100.0,
            amount_gold=1.0,
            description="اختبار سند صرف",
            created_by="pytest",
            status="pending",
        )
        db.session.add(voucher)
        db.session.flush()

        lines = [
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=supplier_account.id,
                line_type="debit",
                amount_type="cash",
                amount=100.0,
            ),
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=cash_account.id,
                line_type="credit",
                amount_type="cash",
                amount=100.0,
            ),
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=supplier_account.id,
                line_type="debit",
                amount_type="gold",
                amount=1.0,
                karat=21,
            ),
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=gold_account.id,
                line_type="credit",
                amount_type="gold",
                amount=1.0,
                karat=21,
            ),
        ]
        for l in lines:
            db.session.add(l)

        db.session.commit()

        with app.test_request_context(json={"approved_by": "pytest"}):

            _sign_in_as_system_admin()
            resp = approve_voucher(voucher.id)

        # Approve returns (json, status) in some cases.
        if isinstance(resp, tuple):
            _, status = resp
        else:
            status = 200
        assert status == 200

        db.session.refresh(voucher)
        assert voucher.journal_entry_id is not None

        jel = JournalEntryLine.query.filter_by(journal_entry_id=voucher.journal_entry_id).all()
        assert jel
        assert all(line.supplier_id == supplier.id for line in jel)
