"""Lazurde's VAT paid in gold, out of the dealings ledger (ADR-089).

The 21.28 g of the 163.1 g bought for Lazurde's wages (PV-2026-00847) that
paid their VAT: left in «دفتر التعامل الوزني» by the opening repair until
the VAT work, to «مشتريات ذهب كسر من العملاء وزني», the twin of where its
riyals are. Neither profit moves. Runs after tools/repair/vat_2026_expense.py.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/lazurde_vat_gold.py
Apply (one transaction, commits once; a second run finds it done):
    python tools/repair/lazurde_vat_gold.py --apply --by <name>
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

FIGURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'services', 'repair',
                       'lazurde_vat_gold.json')


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
