import pytest

from app import app
from models import db, Account, Supplier, Customer
from party_account_service import ensure_supplier_accounts, ensure_customer_accounts


def _ensure_account_number(number: str, *, name: str, acc_type: str) -> Account:
    acc = Account.query.filter_by(account_number=str(number)).first()
    if acc:
        return acc
    acc = Account(
        account_number=str(number),
        name=name,
        type=acc_type,
        transaction_type='cash',
        tracks_weight=False,
    )
    db.session.add(acc)
    db.session.flush()
    return acc


def test_supplier_account_capacity_expanded_under_2100():
    """Supplier accounts under 2100 should support >10 suppliers without exhausting capacity."""

    with app.app_context():
        supplier_group = _ensure_account_number('210', name='موردو ذهب', acc_type='Liability')
        supplier_root = _ensure_account_number('2100', name='حسابات موردو ذهب', acc_type='Liability')
        supplier_root.parent_id = supplier_group.id
        db.session.flush()

        created_numbers: set[str] = set()
        for i in range(12):
            supplier = Supplier(
                supplier_code=f"S-TCAP-{i:06d}",
                name=f"مورد سعة {i}",
                account_category_id=supplier_root.id,
            )
            db.session.add(supplier)
            db.session.flush()

            ensure_supplier_accounts(supplier)

            financial = db.session.get(Account, supplier.account_id)
            assert financial is not None
            assert financial.parent_id == supplier_root.id
            created_numbers.add(financial.account_number)

        db.session.commit()
        assert len(created_numbers) == 12


def test_customer_account_created_under_1200_category():
    """ensure_customer_accounts should create a financial child account under category 1200."""

    with app.app_context():
        category_1200 = _ensure_account_number('1200', name='حسابات العملاء', acc_type='Asset')

        customer = Customer(customer_code='C-TCAP-000001', name='عميل سعة 1200')
        customer.account_category_id = category_1200.id
        db.session.add(customer)
        db.session.flush()

        ensure_customer_accounts(customer)
        db.session.commit()

        financial = db.session.get(Account, customer.account_id)
        assert financial is not None
        assert financial.parent_id == category_1200.id
