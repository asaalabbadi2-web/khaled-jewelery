"""The months crowned twice by the rounding, kept with their leader alone (the owner, 3 Nov 2026).

services/repair/race_crowns_rounding.py: a month kept with more than one crown
is measured again as the points are, among those it crowned; the crowns of
those not at the top go, with an audit row. On the 2 Nov copy: June 2026,
يوسف's crown (1,078.596 against عبدالله's 1,079.29).

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/race_crowns_rounding.py
Apply (one transaction, commits once):
    python tools/repair/race_crowns_rounding.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='race_crowns_rounding', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.race_crowns_rounding import correct_rounded_ties

    with app.app_context():
        try:
            plan = correct_rounded_ties(by=args.by, dry_run=not args.apply)
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
