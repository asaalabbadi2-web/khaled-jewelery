"""The 2026 VAT burden as a non-recoverable VAT expense (ADR-089 amendment).

Each quarter's net VAT -- its output less the input it recovered -- moves
from the sales and «ضريبة مدخلات مستردة من الإقرار» to «ضريبة القيمة المضافة
الغير قابلة للاسترداد», which the weight profit reads as riyals out; Q4
2025's net, a refund, to «ضريبة مستردة من الهيئة», marked as revenue in it.
The cash profit does not move. Runs after tools/repair/vat_2026.py.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/vat_2026_expense.py
Apply (one transaction, commits once; a second run finds it done):
    python tools/repair/vat_2026_expense.py --apply --by <name>
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

FIGURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'services', 'repair',
                       'vat_2026_expense.json')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='repair', help='who applies it (recorded)')
    args = ap.parse_args(argv)
    from app import app
    from models import db
    from services.repair.vat_2026 import apply, load

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            result = apply(by=args.by, now=now, figures=load(os.path.abspath(FIGURES)))
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
