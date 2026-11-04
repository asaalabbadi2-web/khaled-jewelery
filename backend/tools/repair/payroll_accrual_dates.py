"""Payroll runs' accruals put on their month's last day.

services/repair/payroll_accrual_dates.py: an accrual dated the day its run
was approved (October's, 2 November, on the 2 Nov copy) -- and its reversal --
is put on its run's month's last day, with an audit row.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/payroll_accrual_dates.py
Apply (one transaction, commits once):
    python tools/repair/payroll_accrual_dates.py --apply --by <name>

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
    ap.add_argument('--by', default='payroll_accrual_dates', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.payroll_accrual_dates import redate_accruals

    with app.app_context():
        try:
            plan = redate_accruals(by=args.by, dry_run=not args.apply)
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
