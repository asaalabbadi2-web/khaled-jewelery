"""Give back the gold a retracted invoice still counts as gone.

Incident, 2026-09-26: sales invoice 3123 (3.3 g of 22k, display box) was
unposted from the posting screen and rejected. Its creation-time
invoice_sale_gold_movement was never reversed, so the box's movement statement
still shows the gold as sold -- while its replacement 3124 moved the same 3.3 g
out. The box statement reads 6.6 g gone for 3.3 g actually sold.

The code path is fixed: posting_routes._append_safe_reversal_transactions_for_
invoice_gold now reverses sale movements too. This applies THE SAME function,
once, to invoices retracted before that fix -- one writer for both, no
hand-written rows.

Measured before writing it, on the post-incident production copy: in all of
production exactly ONE retracted invoice carries leftover gold movements --
3123 (-3.3 g of 22k, box 30).

Safety:
  - Refuses posted invoices and invoices that are not retracted. Reversing a
    standing sale's movement would hide gold that really left the shop.
  - Dry-run by default: prints what WOULD be written, then rolls back.
  - Idempotent: the function nets every movement, so a second run writes nothing.

Usage (production, inside the backend container, from /app/backend):
    python tools/maintenance/reverse_retracted_invoice_gold.py --invoice-ids 3123
    python tools/maintenance/reverse_retracted_invoice_gold.py --invoice-ids 3123 --apply
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


class Refused(Exception):
    pass


def reverse_for_invoice(invoice_id: int, *, created_by: str = 'maintenance') -> list:
    """Reverse whatever gold *invoice_id* still counts as moved. Writes to the
    session and returns the new rows; committing is the caller's decision."""
    from models import Invoice
    from posting_routes import _append_safe_reversal_transactions_for_invoice_gold
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES

    inv = Invoice.query.get(invoice_id)
    if inv is None:
        raise Refused(f'invoice {invoice_id}: not found')
    if inv.is_posted:
        raise Refused(f'invoice {invoice_id}: is posted -- its gold really left; refusing')
    status = (inv.status or '').strip().lower()
    if status not in RETRACTED_INVOICE_STATUSES:
        raise Refused(f'invoice {invoice_id}: status {inv.status!r} is not retracted; refusing')

    return _append_safe_reversal_transactions_for_invoice_gold(
        inv, created_by=created_by,
        reason=f'عكس ذهب فاتورة ملغاة لم يُعكس عند إلغائها (حادثة 3123) — فاتورة {invoice_id}',
    )


def _describe(t) -> str:
    grams = {k: float(getattr(t, f'weight_{k}k') or 0) for k in (18, 21, 22, 24)}
    shown = ' '.join(f'{v:g}g@{k}k' for k, v in grams.items() if v)
    return f'box={t.safe_box_id} {t.ref_type} {t.direction} {shown}'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--invoice-ids', required=True,
                        help='comma-separated invoice ids, e.g. 3123')
    parser.add_argument('--apply', action='store_true',
                        help='commit; without it this is a dry run')
    args = parser.parse_args(argv)
    ids = [int(x) for x in args.invoice_ids.split(',') if x.strip()]

    from app import app
    from models import db

    with app.app_context():
        written = []
        try:
            for inv_id in ids:
                rows = reverse_for_invoice(inv_id)
                db.session.flush()
                if not rows:
                    print(f'invoice {inv_id}: nothing left to reverse')
                for r in rows:
                    print(f'invoice {inv_id}: {"WRITE" if args.apply else "would write"} {_describe(r)}')
                written += rows
        except Refused as exc:
            db.session.rollback()
            print(f'REFUSED -- {exc}. Nothing was written.')
            return 2

        if args.apply:
            db.session.commit()
            print(f'APPLIED: {len(written)} row(s) committed.')
        else:
            db.session.rollback()
            print(f'DRY RUN: {len(written)} row(s) would be written. Re-run with --apply.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
