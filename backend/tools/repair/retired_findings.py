"""The open findings of a check no job runs any more, closed.

services/repair/retired_findings.py: each open row of a retired kind
(INVENTORY_LEDGER_DRIFT's four on production) is resolved, with an audit row.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/retired_findings.py
Apply (one transaction, commits once):
    python tools/repair/retired_findings.py --apply --by <name>

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
    ap.add_argument('--by', default='retired_findings', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.retired_findings import close_retired_findings

    with app.app_context():
        try:
            plan = close_retired_findings(by=args.by, now=datetime.utcnow(), dry_run=not args.apply)
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
