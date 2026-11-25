"""The commission VAT claimed before its tax invoice, put to wait (ADR-101).

For each method set to issue monthly tax invoices (its tax_invoice_from), the
VAT its settlements and deposits' differences claimed on input VAT from that
month on moves to the method's pending account -- its orders of that month on
-- or to «ضريبة مدخلات مستردة من الإقرار» -- its orders before it, claimed
in their own return. One entry a month (services/repair/commission_vat_wait.py).
Run after the deploy, after setting the methods, before the quarter's return
and before its months are locked.

Dry run by default -- the same run, rolled back, so it shows the real numbers:
    python tools/repair/commission_vat_wait.py [--method <id> ...]
Apply (one transaction, commits once; a second run finds the months done):
    python tools/repair/commission_vat_wait.py --apply --by <name>
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
    ap.add_argument('--method', type=int, action='append', help='a payment method id (default: every one set)')
    args = ap.parse_args(argv)
    from app import app
    from models import PaymentMethod, db
    from services.repair.commission_vat_wait import move

    from datetime import datetime
    now = datetime.now()  # the run's one clock, passed down (ADR-015)
    with app.app_context():
        try:
            q = PaymentMethod.query.filter(PaymentMethod.tax_invoice_from.isnot(None))
            if args.method:
                q = q.filter(PaymentMethod.id.in_(args.method))
            results = [move(pm, by=args.by, now=now) for pm in q.order_by(PaymentMethod.id).all()]
            if args.apply:
                db.session.commit()
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
    print(json.dumps(results, ensure_ascii=False, indent=2, default=str))
    print('APPLIED' if args.apply else 'DRY RUN -- nothing written (rolled back)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
