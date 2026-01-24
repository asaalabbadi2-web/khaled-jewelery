#!/usr/bin/env python3
"""Repair memo (وزني) hierarchy for customers & suppliers.

This enforces the mirrored-hierarchy rule:
- memo_number = '7' + financial.account_number
- memo.parent = memo(financial.parent)

It is safe because it only:
- creates missing memo/group accounts (7xxxxx)
- reparents memo accounts to the correct memo parent
- ensures financial.memo_account_id points to the correct memo

Usage:
  cd backend
  ./venv/bin/python devtools/repair_party_memo_hierarchy.py --execute
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import app, db
from models import Customer, Supplier
from party_account_service import ensure_customer_accounts, ensure_supplier_accounts


def main() -> None:
    execute = '--execute' in sys.argv

    with app.app_context():
        customers = Customer.query.all()
        suppliers = Supplier.query.all()

        changed_customers = 0
        changed_suppliers = 0

        for c in customers:
            before = (c.account_id, getattr(c, 'memo_account_id', None))
            ensure_customer_accounts(c)
            after = (c.account_id, getattr(c, 'memo_account_id', None))
            if before != after:
                changed_customers += 1

        for s in suppliers:
            before = (s.account_id, getattr(s, 'memo_account_id', None))
            ensure_supplier_accounts(s)
            after = (s.account_id, getattr(s, 'memo_account_id', None))
            if before != after:
                changed_suppliers += 1

        if execute:
            db.session.commit()
        else:
            db.session.rollback()

        print('customers_total', len(customers))
        print('suppliers_total', len(suppliers))
        print('customers_touched', changed_customers)
        print('suppliers_touched', changed_suppliers)
        print('mode', 'EXECUTE' if execute else 'DRY_RUN')


if __name__ == '__main__':
    main()
