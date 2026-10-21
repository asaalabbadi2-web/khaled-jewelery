import json

import pytest

@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



def test_posting_approve_voucher_creates_journal_entry_and_safebox_transactions(auth_headers):
    """Regression: posting approval must not be status-only.

    The posting blueprint endpoint `/api/vouchers/approve/<id>` used to approve vouchers
    without creating a JournalEntry nor SafeBoxTransaction rows, causing recurring
    SafeBox vs GL mismatches.
    """

    from app import app
    from models import Account, SafeBox, SafeBoxTransaction, Voucher, VoucherAccountLine, db

    with app.app_context():
        client = app.test_client()

        # Use seeded cash account id=15 and revenue id=400 from conftest.
        cash_account = Account.query.get(15)
        revenue_account = Account.query.get(400)
        assert cash_account is not None
        assert revenue_account is not None

        # Ensure there is an active cash SafeBox mapped to the cash account.
        safe_box = SafeBox.query.filter_by(account_id=cash_account.id, safe_type='cash', is_active=True).first()
        if not safe_box:
            safe_box = SafeBox(
                name='Test Safe 15',
                name_en='Test Safe 15',
                safe_type='cash',
                account_id=cash_account.id,
                is_active=True,
                is_default=False,
            )
            db.session.add(safe_box)
            db.session.commit()

        voucher = Voucher(
            voucher_number='V-TEST-POSTING-1',
            voucher_type='receipt',
            status='pending',
            description='posting approve should create JE and safebox',
        )
        db.session.add(voucher)
        db.session.flush()

        db.session.add(
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=cash_account.id,
                line_type='debit',
                amount_type='cash',
                amount=100.0,
                description='cash in',
            )
        )
        db.session.add(
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=revenue_account.id,
                line_type='credit',
                amount_type='cash',
                amount=100.0,
                description='revenue',
            )
        )
        db.session.commit()

        before_count = SafeBoxTransaction.query.filter_by(ref_type='voucher', ref_id=voucher.id).count()
        assert before_count == 0

        resp = client.post(f'/api/vouchers/approve/{voucher.id}', headers=auth_headers)
        assert resp.status_code == 200, resp.data
        payload = json.loads(resp.data)
        assert payload['success'] is True

        voucher_db = Voucher.query.get(voucher.id)
        assert voucher_db.status == 'approved'
        assert voucher_db.journal_entry_id is not None

        after_count = SafeBoxTransaction.query.filter_by(ref_type='voucher', ref_id=voucher.id).count()
        assert after_count > 0
