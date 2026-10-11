"""ADR-042: the transition to the moving average -- one entry opens the new period with its gold stock right.

services/gold_cost_books.py: at --at (a month's first day, come), 1300 / 1310
land on the pools' value, the suppliers' gold written in riyals on 2100 and
the cash on the pools' weight accounts are cleared, the difference goes to 33.
No income-statement account moves; the past stays as it was posted.

Dry run by default -- writes nothing:
    python tools/repair/gold_cost_transition.py --at 2027-01-01
Apply (one transaction, commits once):
    python tools/repair/gold_cost_transition.py --at 2027-01-01 --apply --by <name>
Run again after a back-dated entry: what moved is written as a further entry.

The opening price: the market's average unless --opening-price is given (the
owner, 11 Oct 2026). Rehearse on a restored copy first (DATABASE_URL=...).
"""
import argparse
import os
import sys
from datetime import date

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--at', required=True, type=date.fromisoformat, help='the transition day (a month\'s first day)')
    ap.add_argument('--opening-price', type=float, default=None, help='riyals per main-karat gram (default: the market average)')
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='gold_cost_transition', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from datetime import datetime
    from app import app
    from models import Account, db
    from services.gold_cost import books_start, market_average_price
    from services.gold_cost_books import write_transition

    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        price = args.opening_price
        if price is None:
            price, *_ = market_average_price(books_start())
        try:
            out = write_transition(by=args.by, now=now, opening_price=price, at=args.at, dry_run=not args.apply)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        name = dict(Account.query.with_entities(Account.account_number, Account.name).all())
        print(f'applied: {bool(args.apply)} · opening price {price:,.2f} · at {args.at}')
        print('pools:', out['pools'])
        print(f'\nthe transition entry ({out["date"]}):')
        for num, amount in sorted(out['lines'].items(), key=lambda kv: -kv[1]):
            print(f'  {"Dr" if amount > 0 else "Cr"} {num:>10} {name.get(num, "")[:34]:34} {abs(amount):16,.2f}')
        print('\nmoved since written (a further entry):', out['drift'] or 'nothing')
        print('written:', out['written'])


if __name__ == '__main__':
    main()
