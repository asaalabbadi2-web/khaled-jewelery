"""Stage 4, the ledger package: every correction the owner decided, in one transaction.

The steps, in order (services/repair/stage4_package.py): rejected invoices
2821 and 3123 reversed at their dates; duplicate payment entries of deleted
invoices reversed; February's duplicate salary voucher cancelled and reversed;
April's deleted payout re-posted; RV-2026-00182 posted; three vouchers whose
entry is posted approved; JE-2026-00851 accepted; the statements of the main
cash box, the Riyadh bank and mada brought to their ledger; the unposting
freeze lifted. Nothing in the ledger touches the main
cash box, the Riyadh bank or the clearing settlement accounts -- their
temporary twins carry what would have moved them (the owner, 3 Oct 2026).

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/s4_package.py
Apply (one transaction for all steps, commits once):
    python tools/repair/s4_package.py --apply --by <name>
One step or a few:
    python tools/repair/s4_package.py --only rejected_invoices,duplicate_salary

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
    ap.add_argument('--by', default='stage4', help='who applies it (recorded)')
    ap.add_argument('--only', default='', help='comma-separated step names (default: all)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.stage4_package import STEPS, run_package

    only = [s.strip() for s in args.only.split(',') if s.strip()]
    unknown = set(only) - {name for name, _ in STEPS}
    if unknown:
        ap.error(f'unknown steps {sorted(unknown)}; known: {[name for name, _ in STEPS]}')
    with app.app_context():
        try:
            plans = run_package(by=args.by, dry_run=not args.apply, only=only or None)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps({'applied': bool(args.apply), 'steps': plans}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
