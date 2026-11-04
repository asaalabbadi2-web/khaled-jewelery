"""An expense posted on the wrong account, moved by an entry at its voucher's date.

services/repair/voucher_expense_reclass.py: each named voucher's amount on
--from moves to --to (an expense account the owner made), by an entry dated
the voucher's own, with an audit row -- once per voucher.

The workers' housing rent (the owner, 5 Nov 2026), after making its account:
    python tools/repair/voucher_expense_reclass.py --from 5410 --to <number> \
        --vouchers PV-2026-00544,PV-2026-00938,PV-2026-01118,PV-2026-01339

Dry run by default -- prints what it would do and writes nothing. Apply
(one transaction, commits once): add --apply --by <name>.

Rehearse on a restored copy first (DATABASE_URL=...).
"""
import argparse
from datetime import datetime
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--vouchers', required=True, help='voucher numbers, comma separated')
    ap.add_argument('--from', dest='from_number', required=True, help='the account it sits on')
    ap.add_argument('--to', dest='to_number', required=True, help='the expense account it moves to')
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='voucher_expense_reclass', help='who applies it (recorded)')
    args = ap.parse_args(argv)
    from app import app
    from models import db
    from services.repair.voucher_expense_reclass import reclassify
    with app.app_context():
        try:
            plan = reclassify(voucher_numbers=[v.strip() for v in args.vouchers.split(',') if v.strip()],
                              from_number=args.from_number, to_number=args.to_number, by=args.by,
                              now=datetime.now(), dry_run=not args.apply)
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
