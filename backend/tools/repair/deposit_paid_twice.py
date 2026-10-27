"""A reservation's deposit its purchase's posting paid again, set right.

services/repair/deposit_paid_twice.py: the posting's second entry reversed
where the deposit voucher stands; where the owner cancelled the voucher, the
payment row gets a voucher on the posting's entry.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/deposit_paid_twice.py
Apply (one transaction, commits once):
    python tools/repair/deposit_paid_twice.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='deposit_paid_twice', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.deposit_paid_twice import set_deposits_paid_twice_right

    with app.app_context():
        try:
            plan = set_deposits_paid_twice_right(by=args.by, now=datetime.now(), dry_run=not args.apply)
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
