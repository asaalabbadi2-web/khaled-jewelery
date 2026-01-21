#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Enforce tracks_weight based on account_number prefix.

Rule:
- If account_number starts with '7' => tracks_weight = True
- Else => tracks_weight = False

This is a data-normalization script to align existing charts of accounts with the
numbering convention used in this project.

Safety:
- Default is DRY RUN (no DB writes).
- Use --apply to commit changes.

Usage (SQLite default in this repo):
  cd backend
  DATABASE_URL=sqlite:///app.db BYPASS_AUTH_FOR_DEVELOPMENT=1 \
    ./venv/bin/python devtools/enforce_tracks_weight_by_prefix.py

  DATABASE_URL=sqlite:///app.db BYPASS_AUTH_FOR_DEVELOPMENT=1 \
    ./venv/bin/python devtools/enforce_tracks_weight_by_prefix.py --apply
"""

import os
import sys

os.environ.setdefault('BYPASS_AUTH_FOR_DEVELOPMENT', '1')

BACKEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from app import app  # noqa: E402
from models import db, Account  # noqa: E402


def _desired_tracks_weight(account_number: str) -> bool:
    n = (account_number or '').strip()
    return n.startswith('7')


def main(argv: list[str]) -> int:
    apply = '--apply' in argv

    with app.app_context():
        accounts = Account.query.order_by(Account.account_number.asc()).all()

        mismatches = []
        for acc in accounts:
            desired = _desired_tracks_weight(acc.account_number)
            if bool(acc.tracks_weight) != desired:
                mismatches.append((acc, desired))

        print(f"Total accounts: {len(accounts)}")
        print(f"Mismatches (prefix rule): {len(mismatches)}")

        for acc, desired in mismatches[:25]:
            prefix = '7' if (acc.account_number or '').strip().startswith('7') else '-'
            print(
                f"- {acc.id}: {acc.account_number} [{prefix}] | tracks_weight={bool(acc.tracks_weight)} -> {desired} | {acc.name}"
            )

        if not apply:
            print('DRY RUN: no changes applied. Re-run with --apply to commit.')
            return 0

        updated = 0
        for acc, desired in mismatches:
            acc.tracks_weight = bool(desired)
            updated += 1

        if updated:
            db.session.commit()
        print(f"Applied updates: {updated}")
        return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
