"""The stopped employees' users stopped; custody links to deleted safes cleared (EMP-1).

services/repair/employee_access_cleanup.py.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/employee_access_cleanup.py
Apply (one transaction, commits once):
    python tools/repair/employee_access_cleanup.py --apply --by <name>

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
    ap.add_argument('--by', default='employee_access_cleanup', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.employee_access_cleanup import cleanup

    with app.app_context():
        try:
            plan = cleanup(by=args.by, now=datetime.now(), dry_run=not args.apply)
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
