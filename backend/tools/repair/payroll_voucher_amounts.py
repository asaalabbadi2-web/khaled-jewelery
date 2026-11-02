"""Salary vouchers' amount on the vouchers' list, written from their own lines.

services/repair/payroll_voucher_amounts.py: a salary's payment voucher (and a
later payment of what was kept owed, an end-of-service settlement's) whose
header amount is 0 gets the sum of its debit lines and its employee, with an
audit row; its lines and its entry are not touched.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/payroll_voucher_amounts.py
Apply (one transaction, commits once):
    python tools/repair/payroll_voucher_amounts.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='payroll_voucher_amounts', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.payroll_voucher_amounts import write_amounts

    with app.app_context():
        try:
            plan = write_amounts(by=args.by, dry_run=not args.apply)
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
