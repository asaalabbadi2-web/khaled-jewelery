"""Run the books invariants against any database — by default writing NOTHING.

    DATABASE_URL=postgresql://…/ref_latest python tools/check_books.py
    DATABASE_URL=postgresql://…/ref_latest python tools/check_books.py --kind GOLD_ATTRIBUTION_MISSING
    python tools/check_books.py --record        # reconcile findings and COMMIT

Made for the reference bench (restored production snapshots): every structural
change is judged by whether the facts it produces on those snapshots are the
facts the incident history says they should be. Dry-run prints one line per
fact, sorted, so two snapshots can be compared with `diff`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--record', action='store_true',
                        help='reconcile findings in reconciliation_findings and commit')
    parser.add_argument('--kind', action='append',
                        help='limit to one kind (repeatable)')
    parser.add_argument('--detail', action='store_true', help='print each fact\'s detail')
    args = parser.parse_args(argv)

    from app import app
    from models import db
    from services.books_invariants import CHECKS, collect_books_facts, run_books_invariants

    with app.app_context():
        if args.record:
            result = run_books_invariants()
            db.session.commit()
            for kind, buckets in result.items():
                print(f"{kind}: " + '  '.join(f"{k}={len(v)}" for k, v in buckets.items()))
            return 0

        facts = collect_books_facts()
        kinds = args.kind or list(CHECKS)
        unknown = [k for k in kinds if k not in CHECKS]
        if unknown:
            print(f'unknown kind(s): {unknown}; known: {list(CHECKS)}', file=sys.stderr)
            return 2
        lines = []
        for kind in kinds:
            for f in facts[kind]:
                line = f'{kind}|{f.subject_key}|{f.metric}'
                if args.detail:
                    line += '|' + json.dumps(f.detail, ensure_ascii=False, sort_keys=True)
                lines.append(line)
        for line in sorted(lines):
            print(line)
        db.session.rollback()   # dry-run: nothing was written; make it explicit
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
