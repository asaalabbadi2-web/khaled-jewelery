"""Payroll entries of a month that is not a month, removed.

services/repair/payroll_stray_periods.py: a pending entry with no accrual and
no voucher whose month is not 1-12 of a four-digit year (#3, «202», on the
31 Oct copy) is removed, with an audit row.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/payroll_stray_periods.py
Apply (one transaction, commits once):
    python tools/repair/payroll_stray_periods.py --apply --by <name>

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
    ap.add_argument('--by', default='payroll_stray_periods', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.payroll_stray_periods import remove_stray_periods

    with app.app_context():
        try:
            plan = remove_stray_periods(by=args.by, dry_run=not args.apply)
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
