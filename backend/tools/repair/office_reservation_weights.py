"""Stage-4 item 8: the old office reservations' gold came from a purchase, not from our scrap stock.

services/repair/office_reservation_weights.py: each of the old reservation
weight entries that credited the scrap stock (71310) gets a transfer, dated as
it, debit 71310 / credit the purchases' weight twin 7512. Weight only.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/office_reservation_weights.py
Apply (one transaction, commits once):
    python tools/repair/office_reservation_weights.py --apply --by <name>

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
    ap.add_argument('--by', default='office_reservation_weights', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.office_reservation_weights import transfer_office_reservation_weights

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            plan = transfer_office_reservation_weights(by=args.by, now=now, dry_run=not args.apply)
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
