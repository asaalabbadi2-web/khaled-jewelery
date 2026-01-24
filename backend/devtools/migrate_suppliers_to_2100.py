#!/usr/bin/env python3
"""Migrate suppliers to use posting category 2100.

Goal:
- Ensure account 2100 exists under 210.
- Ensure every supplier (Supplier.account_category_id) points to 2100.
- Ensure each supplier posting account (Supplier.account_id) is parented under 2100.
- If supplier has no posting account, create via ensure_supplier_accounts.

This is safe because changing an Account.parent_id only affects the chart tree,
not balances or journal lines.

Usage:
  ./venv/bin/python devtools/migrate_suppliers_to_2100.py --execute
"""

import os
import sys
from typing import List, Dict, Any, Optional

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import app, db
from models import Account, Supplier
from party_account_service import ensure_supplier_accounts


def _get_account(number: str) -> Optional[Account]:
    return Account.query.filter_by(account_number=str(number)).first()


def migrate(execute: bool) -> Dict[str, Any]:
    with app.app_context():
        acc_210 = _get_account('210')
        acc_2100 = _get_account('2100')

        if not acc_210:
            raise SystemExit('Missing required account 210')

        if not acc_2100:
            acc_2100 = Account(
                account_number='2100',
                name='حسابات موردو ذهب',
                type=acc_210.type,
                transaction_type='cash',
                tracks_weight=False,
                parent_id=acc_210.id,
            )
            db.session.add(acc_2100)
            db.session.flush()

        # Ensure 2100 is under 210
        if acc_2100.parent_id != acc_210.id:
            acc_2100.parent_id = acc_210.id

        suppliers: List[Supplier] = Supplier.query.all()

        report: Dict[str, Any] = {
            'execute': execute,
            'suppliers_total': len(suppliers),
            'category_updated': 0,
            'account_parent_updated': 0,
            'accounts_created': 0,
            'details': [],
        }

        for supplier in suppliers:
            changed = False
            detail = {
                'supplier_id': supplier.id,
                'supplier_code': supplier.supplier_code,
                'name': supplier.name,
                'old_category_id': supplier.account_category_id,
                'new_category_id': acc_2100.id,
                'old_account_id': supplier.account_id,
                'action': [],
            }

            if supplier.account_category_id != acc_2100.id:
                supplier.account_category_id = acc_2100.id
                report['category_updated'] += 1
                changed = True
                detail['action'].append('set_category_2100')

            if supplier.account_id:
                posting = Account.query.get(supplier.account_id)
                if posting and posting.parent_id != acc_2100.id:
                    posting.parent_id = acc_2100.id
                    report['account_parent_updated'] += 1
                    changed = True
                    detail['action'].append('reparent_posting_to_2100')
            else:
                ensure_supplier_accounts(supplier)
                report['accounts_created'] += 1
                changed = True
                detail['action'].append('created_posting_account')

            if changed:
                report['details'].append(detail)

        if execute:
            db.session.commit()
        else:
            db.session.rollback()

        return report


def main() -> None:
    execute = '--execute' in sys.argv
    report = migrate(execute=execute)

    print('suppliers_total', report['suppliers_total'])
    print('category_updated', report['category_updated'])
    print('account_parent_updated', report['account_parent_updated'])
    print('accounts_created', report['accounts_created'])

    # Print only a small sample to keep output readable
    details = report.get('details') or []
    if details:
        print('\nchanged (first 20):')
        for d in details[:20]:
            print('-', d['supplier_id'], d['supplier_code'], d['name'], 'actions=', d['action'])


if __name__ == '__main__':
    main()
