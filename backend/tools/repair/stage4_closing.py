"""Stage 4's last decisions (the owner, 12 Oct 2026) -- services/repair/stage4_closing.py.

  purchases_paid    -- purchases 64 and 149: the vouchers that paid their rest linked (no entry)
  cash_customer     -- what is left on the cash customer cleared against the temporary cash box
  duplicates        -- the 20 other «عميل نقدي» records, at zero, stopped with their accounts
  temp_bank         -- the temporary bank's statement follows its ledger (AV-2026-00210)
  rounding          -- PV-2026-01293's 0.01 g accepted (item 1 closed)
  weight_column     -- the 16 old entries' weight-equivalent column accepted (the nightly check names new ones)

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/stage4_closing.py
Apply (one transaction, commits once):
    python tools/repair/stage4_closing.py --apply --by <name>
One step only:
    python tools/repair/stage4_closing.py --only cash_customer

Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

STEPS = ('purchases_paid', 'cash_customer', 'duplicates', 'temp_bank', 'rounding', 'weight_column')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='stage4_closing', help='who applies it (recorded)')
    ap.add_argument('--only', choices=STEPS, action='append', help='these steps only')
    args = ap.parse_args(argv)

    from datetime import datetime

    from app import app
    from models import db
    from services.repair import stage4_closing as sc

    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    dry = not args.apply
    steps = args.only or STEPS
    out = {'applied': bool(args.apply)}
    with app.app_context():
        try:
            if 'purchases_paid' in steps:
                out['purchases_paid'] = sc.purchases_paid_by_unnamed_vouchers(by=args.by, now=now, dry_run=dry)
            if 'cash_customer' in steps:
                out['cash_customer'] = sc.cash_customer_cleared(by=args.by, now=now, dry_run=dry)
            if 'duplicates' in steps:
                out['duplicates'] = sc.cash_customer_duplicates(by=args.by, now=now, dry_run=dry)
            if 'temp_bank' in steps:
                out['temp_bank'] = sc.temp_bank_statement(by=args.by, dry_run=dry)
            if 'rounding' in steps:
                out['rounding'] = sc.accept_rounding(by=args.by, now=now, dry_run=dry)
            if 'weight_column' in steps:
                out['weight_column'] = sc.accept_old_weight_column(by=args.by, now=now, dry_run=dry)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps(out, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
