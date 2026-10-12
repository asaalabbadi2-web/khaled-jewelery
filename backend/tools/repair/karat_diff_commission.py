"""Stage-4 item 9 (POST-001): invoice 3020's karat-difference commission, never written by posting.

services/repair/karat_diff_commission.py: the entry posting would have written --
dated as the invoice, keyed to it, debit the supplier / credit 4110, 307.37.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/karat_diff_commission.py
Apply (one transaction, commits once):
    python tools/repair/karat_diff_commission.py --apply --by <name>

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
    ap.add_argument('--by', default='karat_diff_commission', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from datetime import datetime
    from services.repair.karat_diff_commission import post_missing_commissions

    with app.app_context():
        try:
            plan = post_missing_commissions(by=args.by, now=datetime.now(), dry_run=not args.apply)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps({'applied': bool(args.apply), 'invoices': plan}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
