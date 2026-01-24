"""Inspect party account roots in the local DB.

Usage:
    ./venv/bin/python devtools/inspect_coa_party_roots.py
"""

import os
import sys


# Ensure backend/ directory is on sys.path when running from backend/devtools.
_BACKEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if _BACKEND_DIR not in sys.path:
        sys.path.insert(0, _BACKEND_DIR)


from typing import List, Optional

from app import app
from models import Account, Customer, Supplier, db


def _show_root(number: str) -> None:
    root = Account.query.filter_by(account_number=str(number)).first()
    print(
        "ROOT",
        number,
        "exists=",
        bool(root),
        "id=",
        getattr(root, "id", None),
        "name=",
        getattr(root, "name", None),
        "type=",
        getattr(root, "type", None),
        "tx=",
        getattr(root, "transaction_type", None),
        "tracks_weight=",
        getattr(root, "tracks_weight", None),
    )

    if not root:
        return

    kids = (
        Account.query.filter_by(parent_id=root.id)
        .order_by(db.cast(Account.account_number, db.Integer))
        .all()
    )
    print("  children:", len(kids))
    for child in kids[:25]:
        print("   -", child.account_number, child.name)
    if len(kids) > 25:
        print("   ...")


def _count_parented_accounts(entity_name: str, parent: Optional[Account], account_ids: List[int]) -> None:
    if not parent:
        print(entity_name, "parent_missing")
        return

    parents: list[int] = []
    for account_id in account_ids:
        a = db.session.get(Account, account_id)
        if a:
            parents.append(a.parent_id)

    print(entity_name, "with_accounts=", len(parents))
    print(entity_name, f"parent_{parent.account_number}=", parents.count(parent.id))


def main() -> None:
    with app.app_context():
        for num in ("1200", "1100", "210", "220", "110", "120", "21"):
            _show_root(num)

        root_1200 = Account.query.filter_by(account_number="1200").first()
        root_1100 = Account.query.filter_by(account_number="1100").first()
        root_210 = Account.query.filter_by(account_number="210").first()

        customer_account_ids = [c.account_id for c in Customer.query.filter(Customer.account_id.isnot(None)).all() if c.account_id]
        supplier_account_ids = [s.account_id for s in Supplier.query.filter(Supplier.account_id.isnot(None)).all() if s.account_id]

        _count_parented_accounts("customers", root_1200, customer_account_ids)
        _count_parented_accounts("customers", root_1100, customer_account_ids)
        _count_parented_accounts("suppliers", root_210, supplier_account_ids)


if __name__ == "__main__":
    main()
