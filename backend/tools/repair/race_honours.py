"""The race card's crowns and targets filled for the periods closed before they were kept (bonus study م3هـ).

Each closed period from --since (default: the first posted sale or customer
purchase) until today: a month's leaders by points, and each goal period
reached. A goal's past periods are measured against its target as it is now.
Each period is written once; a second run finds nothing.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/race_honours.py
Apply (one transaction, commits once):
    python tools/repair/race_honours.py --apply
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
    ap.add_argument('--since', help='YYYY-MM-DD (default: the first posted sale or customer purchase)')
    args = ap.parse_args(argv)
    from datetime import date, datetime

    from app import app
    from models import Employee, Invoice, db
    from services.race_honours import backfill

    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            if args.since:
                since = datetime.strptime(args.since, '%Y-%m-%d').date()
            else:
                first = (db.session.query(db.func.min(Invoice.date))
                         .filter(Invoice.is_posted.is_(True), Invoice.invoice_type.in_(('بيع', 'شراء من عميل')))
                         .scalar())
                since = first.date().replace(day=1) if first else now.date()
            kept = backfill(since, now.date(), now)
            names = {e.id: e.name for e in Employee.query.all()}
            result = {
                'since': since.isoformat(),
                'leaders': [f'{h.period_start:%Y-%m} {names.get(h.employee_id)} ({h.value:g})'
                            for h in kept if h.kind == 'leader'],
                'goals': [f'{h.period} {h.period_start} {names.get(h.employee_id)} ({h.value:g} / {h.target:g})'
                          for h in kept if h.kind == 'goal'],
            }
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
