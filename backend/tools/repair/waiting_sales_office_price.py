"""The sales still waiting to become gold, measured against the office's price.

services/repair/waiting_sales_office_price.py: each waiting sale recorded
before the office's terms keeps its scrap price at the office's price.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/waiting_sales_office_price.py
Apply (one transaction, commits once):
    python tools/repair/waiting_sales_office_price.py --apply --by <name>

Run after the deploy has saved one price with the office's terms (the first
price fetched after it). Rehearse on a restored copy first (DATABASE_URL=...).
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
    ap.add_argument('--by', default='waiting_sales_office_price', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.waiting_sales_office_price import reprice_waiting_sales

    with app.app_context():
        try:
            plan = reprice_waiting_sales(by=args.by, now=datetime.now(), dry_run=not args.apply)
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
