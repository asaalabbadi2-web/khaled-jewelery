"""The gold an older writer left on the main cash box, moved to the purchases (the owner, 14 Nov 2026).

JE-2026-00066 («شراء من عميل» #1, 17 Feb 2026) credited its 98.26 g of 24k to
«صندوق النقدية الرئيسي وزني»; this writes one entry, dated as it, moving the
line's grams to the purchases' weight twin. Every figure from the line;
refuses, writing nothing, when the books are not as found
(services/repair/cash_safe_gold.py). Run before the month is locked.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/cash_safe_gold.py
Apply (one transaction, commits once; a second run finds it done):
    python tools/repair/cash_safe_gold.py --apply --by <name>
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
    ap.add_argument('--entry', default='JE-2026-00066', help='the entry whose cash safe line moves')
    args = ap.parse_args(argv)
    from app import app
    from models import db
    from services.repair.cash_safe_gold import move

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            result = move(by=args.by, now=now, entry_number=args.entry)
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
