"""The gold sold that sat on the customers' weight twins, moved by month (CUSTGOLD-001).

services/repair/customer_gold_to_cost_of_sales.py: each month's net on the
customers' weight twins (712…) moves by one entry dated the month's last day
-- a sale's to the cost of sales by weight, a customer purchase's to its
purchases by weight. Lines from anything else are listed in "left", not moved.

After the release that puts the writer right (a sale's grams on the cost of
sales by weight), once:
    python tools/repair/customer_gold_to_cost_of_sales.py

Dry run by default -- prints what it would do and writes nothing. Apply
(one transaction, commits once): add --apply --by <name>. Run again, it
moves nothing more.

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
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='customer_gold_to_cost_of_sales', help='who applies it (recorded)')
    args = ap.parse_args(argv)
    from app import app
    from models import db
    from services.repair.customer_gold_to_cost_of_sales import move
    with app.app_context():
        try:
            plan = move(by=args.by, now=datetime.now(), dry_run=not args.apply)
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
