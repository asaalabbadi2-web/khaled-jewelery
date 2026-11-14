"""Two payments of 30 March 2026 that sat in the safes shortage (ADR-088).

The owner (15 Nov 2026): paid and never entered -- 46,173 an advance on the
shop's zakat for 2026, and 20,000 the workers' bonuses. Each reached «عجز /
فائض الخزائن» through the reconciliations, so each is corrected there:
the advance on «زكاة مدفوعة مقدَّمًا», an asset it makes under the current
assets (set against the year's zakat when computed), the bonuses on the bonus expense. Figures in
services/repair/shortage_2026_unrecorded.json; refuses, writing nothing,
when the books differ from what it found, or end other than it says.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/shortage_2026_unrecorded.py
Apply (one transaction, commits once; a second run finds it done):
    python tools/repair/shortage_2026_unrecorded.py --apply --by <name>
Rehearse on a restored copy first (DATABASE_URL=...), then on production.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

FIGURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'services', 'repair',
                       'shortage_2026_unrecorded.json')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--apply', action='store_true', help='write (default: dry run)')
    ap.add_argument('--by', default='repair', help='who applies it (recorded)')
    args = ap.parse_args(argv)
    from app import app
    from models import db
    from services.repair.vat_2026 import apply, load

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            result = apply(by=args.by, now=now, figures=load(os.path.abspath(FIGURES)))
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
