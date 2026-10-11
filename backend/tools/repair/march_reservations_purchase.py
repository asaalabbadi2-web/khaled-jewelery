"""Stage-4 item 21: two office reservations paid in cash in March -- their gold a purchase, not a debt to the office.

services/repair/march_reservations_purchase.py: on AV-2026-00012's date, the
purchase (debit the office's weight account 72100021 / credit 7512; debit 512 /
credit the office 21000020, 116,378); on JE-2026-04561's date, its reversal.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/march_reservations_purchase.py
Apply (one transaction, commits once):
    python tools/repair/march_reservations_purchase.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='march_reservations_purchase', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.march_reservations_purchase import record_march_reservations_purchase

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            plan = record_march_reservations_purchase(by=args.by, now=now, dry_run=not args.apply)
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
