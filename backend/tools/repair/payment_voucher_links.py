"""Stage-4 item 2 (LINK-001): a supplier purchase's payment voucher linked to the payment row it made.

services/repair/payment_voucher_links.py: an approved payment voucher on a
supplier purchase with no row linked to it, and exactly one unlinked payment
row of its amount on that invoice, gets the link (source_voucher_id). No
amount moves; anything not one-to-one is said, not linked.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/payment_voucher_links.py
Apply (one transaction, commits once):
    python tools/repair/payment_voucher_links.py --apply --by <name>

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
    ap.add_argument('--by', default='payment_voucher_links', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.payment_voucher_links import link_payment_vouchers

    with app.app_context():
        try:
            plan = link_payment_vouchers(by=args.by, dry_run=not args.apply)
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
