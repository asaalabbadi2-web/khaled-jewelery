"""The rent of 2026 in two: as paid, and net -- the months restated in their months (ADR-090).

services/repair/rent_2026_split.py from the owner's figures
(services/repair/rent_2026_split.json). Runs after tools/repair/period_expense_2026.py,
before the December voucher is linked, and before July-October are closed.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/rent_2026_split.py
Apply (one transaction, commits once; a second run finds it done):
    python tools/repair/rent_2026_split.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import datetime as dt
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--through', help="a month's last day (default: last month's end)")
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='rent_2026_split', help='who applies it (recorded)')
    args = ap.parse_args(argv)
    now = dt.datetime.now()  # clock-guard: boundary
    through = (dt.date.fromisoformat(args.through) if args.through
               else now.date().replace(day=1) - dt.timedelta(days=1))

    from app import app
    from models import db
    from services.repair.rent_2026_split import apply

    with app.app_context():
        try:
            plan = apply(through=through, by=args.by, now=now, dry_run=not args.apply)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps(plan, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
