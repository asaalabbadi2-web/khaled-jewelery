"""Utilities to keep Office and Supplier records in sync."""
from __future__ import annotations

from typing import Optional

from models import db, Office, Supplier
from code_generator import generate_supplier_code
from office_account_service import ensure_office_parent_account


def _sync_supplier_account_with_office(supplier: Supplier, office: Office) -> None:
    """Ensure supplier.account_id points to the same account as office.account_category_id.

    This prevents a second account from being silently created by ensure_supplier_accounts()
    when a payment voucher targets the supplier directly (instead of via the reservation flow).
    """
    office_account_id = getattr(office, 'account_category_id', None) or None
    if not office_account_id:
        return
    if getattr(supplier, 'account_id', None) != int(office_account_id):
        supplier.account_id = int(office_account_id)
        db.session.add(supplier)
        db.session.flush()


def ensure_office_supplier(office: Office, *, auto_commit: bool = False) -> Supplier:
    """Ensure the given office has a dedicated supplier record and return it."""
    if not office:
        raise ValueError('office is required to ensure supplier linkage')

    if office.supplier:
        # Sync: if the office account was created after the supplier, backfill account_id.
        _sync_supplier_account_with_office(office.supplier, office)
        return office.supplier

    # Supplier.account_category_id is a category/root (e.g. 2200/2100), not the office posting account.
    try:
        supplier_category = ensure_office_parent_account()
        supplier_category_id = int(getattr(supplier_category, 'id', None)) if supplier_category else None
    except Exception:
        supplier_category_id = None

    # If the office already has a dedicated posting account (account_category_id), we reuse it
    # as the supplier's financial account so that ALL payment flows (reservation + manual vouchers)
    # post to exactly ONE account.  Without this link, ensure_supplier_accounts() would later
    # allocate a SECOND account for the same office, causing irreconcilable balance splits.
    office_account_id = getattr(office, 'account_category_id', None) or None

    supplier = Supplier(
        supplier_code=generate_supplier_code(),
        name=office.name,
        phone=office.phone,
        email=office.email,
        account_category_id=supplier_category_id,
        account_id=int(office_account_id) if office_account_id else None,
        notes=f'مورد مرتبط بالمكتب {office.office_code}',
        active=office.active,
        gold_balance_weight=0.0,
        gold_balance_cash_equivalent=0.0,
    )
    db.session.add(supplier)
    db.session.flush()

    office.supplier_id = supplier.id
    db.session.add(office)

    if auto_commit:
        db.session.commit()

    return supplier


def ensure_office_supplier_by_id(office_id: int, *, auto_commit: bool = False) -> Optional[Supplier]:
    """Helper that fetches an office by ID and ensures its supplier linkage."""
    office = Office.query.get(office_id)
    if not office:
        return None
    return ensure_office_supplier(office, auto_commit=auto_commit)
