"""Grams left on a cash account move to its weight twin (ADR-051) -- one correction per entry, at its date.

On the 17 Oct production copy: JE-2026-06478's 1,677.171 g of 21k on 2100001
(the Arab pound) move to 72100001, the weight account its safe reads.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/weight_to_weight_twin.py
Apply (one transaction, commits once; a second run finds it done):
    python tools/repair/weight_to_weight_twin.py --apply --by <name>
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
    from services.repair.weight_to_weight_twin import move_grams_to_weight_twin

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            plans = move_grams_to_weight_twin(by=args.by, now=now, dry_run=not args.apply)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps({'applied': bool(args.apply), 'entries': plans}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
