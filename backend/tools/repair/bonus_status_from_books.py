"""The bonuses' statuses put right by the books (PAYROLL-4).

services/repair/bonus_status_from_books.py: a bonus «paid» whose payment
voucher was cancelled is approved again when its account still owes it; an
employee's approved bonuses are paid when his account owes nothing. The rest
is listed.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/bonus_status_from_books.py
Apply (one transaction, commits once):
    python tools/repair/bonus_status_from_books.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...).
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
    ap.add_argument('--by', default='bonus_status_from_books', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.bonus_status_from_books import settle

    with app.app_context():
        try:
            plan = settle(by=args.by, now=datetime.now(), dry_run=not args.apply)
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
