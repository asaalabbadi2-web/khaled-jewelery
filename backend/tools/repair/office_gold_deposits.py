"""Each office's gold becomes a deposit, as money in a bank (ADR-052).

Makes «ذهب مودع لدى المكاتب» (its role mapped), a deposit and its safe per
office, makes it the office's gold safe, stops the old safe on the supplier
account, and moves our gold there in one entry per office at today's date.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/office_gold_deposits.py
Apply (one transaction, commits once; a second run finds it done):
    python tools/repair/office_gold_deposits.py --apply --by <name>
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
    ap.add_argument('--by', default='repair', help='who applies it (recorded)')
    args = ap.parse_args(argv)
    from app import app
    from models import db
    from services.repair.office_gold_deposits import make_deposits

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            result = make_deposits(by=args.by, now=now)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))
    print('APPLIED' if args.apply else 'DRY RUN -- nothing written (rolled back)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
