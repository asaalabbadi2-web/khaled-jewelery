"""CHART-001: the chart put in order -- services/repair/chart_001.py. No entry, no balance.

  move   -- 2310 and 2320 with their children to 24 «أرصدة دائنة أخرى», numbered as they are; 2310 named for what it holds
  zakat  -- 235 «الزكاة المستحقة» under 23
  twins  -- the weight twins of input VAT (14), collections (15), tax liabilities (23), employee payables (24) stopped
  types  -- 72 a liability, 74 a revenue, 510 not a weight account

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/chart_001.py
Apply (one transaction, commits once):
    python tools/repair/chart_001.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    from services.repair.chart_001 import STEPS
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='chart_001', help='who applies it (recorded)')
    ap.add_argument('--only', choices=STEPS, action='append', help='these steps only')
    args = ap.parse_args(argv)

    from datetime import datetime

    from app import app
    from models import db
    from services.repair import chart_001

    with app.app_context():
        try:
            out = chart_001.apply(by=args.by, now=datetime.now(), dry_run=not args.apply, steps=args.only)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps({'applied': bool(args.apply), **out}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
