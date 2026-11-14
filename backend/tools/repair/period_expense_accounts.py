"""The period expenses' two accounts made and mapped (ADR-090, phase 3).

services/repair/period_expense_accounts.py: «مصروفات مقدَّمة» made under
--prepaid-under (an assets parent) and «مصروفات مستحقة» under --accrued-under
(a liabilities parent), each mapped to its role. A role already mapped is kept.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/period_expense_accounts.py --prepaid-under 11 --accrued-under 2
Apply (one transaction, commits once):
    python tools/repair/period_expense_accounts.py --prepaid-under 11 --accrued-under 2 --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--prepaid-under', required=True, help='the assets parent «مصروفات مقدَّمة» is made under')
    ap.add_argument('--accrued-under', required=True, help='the liabilities parent «مصروفات مستحقة» is made under')
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='period_expense_accounts', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.period_expense_accounts import setup

    with app.app_context():
        try:
            plan = setup(by=args.by, prepaid_under=args.prepaid_under, accrued_under=args.accrued_under,
                         dry_run=not args.apply)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps({'applied': bool(args.apply), **plan}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
