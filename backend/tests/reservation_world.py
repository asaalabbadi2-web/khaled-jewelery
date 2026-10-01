"""Office-reservation accounts as production has them (SAFEBOX-001, 1 Oct 2026).

Settlement records the gold bought: Dr the office's weight account / Cr the
weight twin of the purchases account. In production the office's financial
account carries a weight twin (memo_account_id) and 512 carries 7512; a test
world without them is refused settlement (reservation_weight_accounts_missing),
as a misconfigured production would be.
"""
import uuid

from models import Account, db


def with_weight_twins(office_account):
    """Give *office_account* a weight twin, and 512 its 7512."""
    if not office_account.memo_account_id:
        twin = Account(account_number=f'721{uuid.uuid4().int % 10**6:06d}', name=f'{office_account.name} وزني',
                       type='Liability', transaction_type='gold', tracks_weight=True)
        db.session.add(twin)
        db.session.flush()
        office_account.memo_account_id = twin.id
    purchases = Account.query.filter_by(account_number='512').first()
    if purchases is None:
        purchases = Account(account_number='512', name='مشتريات ذهب كسر', type='Expense', transaction_type='cash')
        db.session.add(purchases)
        db.session.flush()
    if not purchases.memo_account_id:
        twin = Account.query.filter_by(account_number='7512').first()
        if twin is None:
            twin = Account(account_number='7512', name='مشتريات ذهب كسر وزني', type='Expense',
                           transaction_type='gold', tracks_weight=True)
            db.session.add(twin)
            db.session.flush()
        purchases.memo_account_id = twin.id
    db.session.flush()
    return office_account
