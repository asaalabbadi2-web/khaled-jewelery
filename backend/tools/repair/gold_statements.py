"""Stage-4 items 12, 13 and 15: gold safes -- the statement follows the ledger, one ledger correction, two accepted copies.

services/repair/gold_statements.py, in this order:
  duplicate_992  -- the second purchase of invoice 992 (JE-2026-01881): debit 7512 /
                    credit the reserve scrap safe 71310002; the main scrap safe untouched
  manual_copies  -- the main scrap safe's and Al-Raqi's findings, rows copying a manual
                    entry, accepted with their entries; nothing written
  align          -- the display safe's (71300) and Al-Junaih's (72100001) statements
                    brought to their ledgers, document by document; balances do not move

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/gold_statements.py
Apply (one transaction, commits once):
    python tools/repair/gold_statements.py --apply --by <name>
One step only:
    python tools/repair/gold_statements.py --only align

Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

STEPS = ('duplicate_992', 'manual_copies', 'align')
ALIGN = ('71300', '72100001')   # the display safe, Al-Junaih


def _safe_of(number):
    from models import Account, SafeBox
    account = Account.query.filter_by(account_number=number).first()
    safe = account and SafeBox.query.filter_by(account_id=account.id).first()
    if safe is None:
        raise SystemExit(f'no safe on account {number}')
    return safe


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='gold_statements', help='who applies it (recorded)')
    ap.add_argument('--only', choices=STEPS, action='append', help='these steps only')
    args = ap.parse_args(argv)

    from datetime import datetime

    from app import app
    from models import db
    from services.repair import gold_statements as gs

    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    dry = not args.apply
    steps = args.only or STEPS
    out = {'applied': bool(args.apply)}
    with app.app_context():
        try:
            if 'duplicate_992' in steps:
                out['duplicate_992'] = gs.duplicate_purchase_992(by=args.by, now=now, dry_run=dry)
            if 'manual_copies' in steps:
                out['manual_copies'] = gs.accept_manual_copies(by=args.by, now=now, dry_run=dry)
            if 'align' in steps:
                out['align'] = [gs.align_gold_statement(_safe_of(n).id, by=args.by, dry_run=dry) for n in ALIGN]
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
