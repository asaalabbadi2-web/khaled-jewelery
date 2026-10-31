"""The payroll run's accounts made and mapped (PAYROLL-3).

services/repair/payroll_accounts.py: «التأمينات الاجتماعية المستحقة» and
«جزاءات العاملين المستحقة» made under --under and mapped; the contributions
expense mapped to --contributions-expense; with --eos-expense-under, «مصروف
مكافأة نهاية الخدمة» made there and mapped. A role already mapped is kept.

Dry run by default -- prints what it would do and writes nothing:
    python tools/repair/payroll_accounts.py --under 24 --contributions-expense 5480 --eos-expense-under 540
Apply (one transaction, commits once):
    python tools/repair/payroll_accounts.py --under 24 --contributions-expense 5480 --eos-expense-under 540 --apply --by <name>

Rehearse on a restored copy first (DATABASE_URL=...).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--under', required=True, help='the liabilities parent the two accounts are made under')
    ap.add_argument('--contributions-expense', required=True, help='the expense account of the employer share')
    ap.add_argument('--eos-expense-under', help='the expenses parent the end-of-service expense is made under')
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='payroll_accounts', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from app import app
    from models import db
    from services.repair.payroll_accounts import setup

    with app.app_context():
        try:
            plan = setup(by=args.by, under=args.under, contributions_expense=args.contributions_expense,
                         eos_expense_under=args.eos_expense_under, dry_run=not args.apply)
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
        print(json.dumps({'applied': bool(args.apply), **plan}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
