"""An expense booked on a group account, moved to its own account (the owner, 17 Nov 2026).

JE-2026-02177 (15 May 2026) debited 1,000 riyals to «5 المصروفات» itself; the
owner: «رواتب الاداريين والمحاسبين» -- 5470. This writes one entry, dated as
it, moving the line's riyals there; refuses, writing nothing, when the books
are not as found (services/repair/expense_on_group.py). Run before May is
locked.

The accounts are named on the command line, by the owner's word -- not in the code.
Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/expense_on_group.py --entry JE-2026-02177 --from-account 5 --to-account 5470
Apply (one transaction, commits once; a second run finds it done): the same with
    --apply --by <name>
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
    ap.add_argument('--entry', required=True, help='the entry whose line on the group moves')
    ap.add_argument('--from-account', required=True, help='the group it was booked on, by its number')
    ap.add_argument('--to-account', required=True, help='the account it belongs to, by its number')
    args = ap.parse_args(argv)
    from app import app
    from models import db
    from services.repair.expense_on_group import move

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            result = move(by=args.by, now=now, entry_number=args.entry, from_number=args.from_account,
                          to_number=args.to_account)
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
