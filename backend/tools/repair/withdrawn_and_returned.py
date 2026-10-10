"""What a withdrawn sale and a sale return left behind (the owner, 10 Oct 2026).

Steps (services/repair/withdrawn_and_returned.py): the open weight-closing
orders of rejected sales 2821, 3123 and 3303 cancelled (5,706 g); the five
sale returns' lines given their original lines' categories, with the
inventory ledger reposted and the category weights written. No journal entry.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/withdrawn_and_returned.py
Apply (one transaction, commits once):
    python tools/repair/withdrawn_and_returned.py --apply --by <name>

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
    ap.add_argument('--by', default='withdrawn_and_returned', help='who applies it (recorded)')
    ap.add_argument('--only', default='', help='comma-separated step names (default: all)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.withdrawn_and_returned import STEPS, run_package

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    only = [s.strip() for s in args.only.split(',') if s.strip()]
    unknown = set(only) - {name for name, _ in STEPS}
    if unknown:
        ap.error(f'unknown steps {sorted(unknown)}; known: {[name for name, _ in STEPS]}')
    with app.app_context():
        try:
            plans = run_package(by=args.by, now=now, dry_run=not args.apply, only=only or None)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps({'applied': bool(args.apply), 'steps': plans}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
