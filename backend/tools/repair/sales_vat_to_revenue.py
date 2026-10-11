"""Stage-4 item 22: the sales VAT of January-May 2026 is revenue -- one entry at each month's end.

services/repair/sales_vat_to_revenue.py: each invoice entry's VAT (2300, and
2210 for three April returns) goes to the revenue account that entry
credited (41 / 400; a return's 420). Nothing posted is edited.

Dry run by default -- prints each month's entry, writes nothing:
    python tools/repair/sales_vat_to_revenue.py
Apply (one transaction, commits once):
    python tools/repair/sales_vat_to_revenue.py --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import os
import sys
from datetime import date

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--before', type=date.fromisoformat, default=date(2026, 6, 1),
                    help='the first day not moved (the owner: before 1 June 2026)')
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='sales_vat_to_revenue', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from datetime import datetime
    from app import app
    from models import Account, db
    from services.repair.sales_vat_to_revenue import move_sales_vat_to_revenue

    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            out = move_sales_vat_to_revenue(by=args.by, now=now, before=args.before, dry_run=not args.apply)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        name = dict(Account.query.with_entities(Account.account_number, Account.name).all())
        print(f'applied: {bool(args.apply)} · before {args.before}')
        total = 0.0
        for m in out['months']:
            print(f'\n{m["month"]}  ({m["date"]})' + ('  -- already written' if m['month'] in out['already'] else ''))
            for num, amount in sorted(m['lines'].items(), key=lambda kv: -kv[1]):
                print(f'  {"Dr" if amount > 0 else "Cr"} {num:>8} {name.get(num, "")[:30]:30} {abs(amount):14,.2f}')
            total += sum(a for n, a in m['lines'].items() if a > 0 and n in ('2300', '2210'))
        print(f'\nVAT moved (debits on 2300 / 2210): {total:,.2f}')
        print('written:', out['written'])


if __name__ == '__main__':
    main()
