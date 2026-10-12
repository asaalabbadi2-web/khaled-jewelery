"""A supplier purchase's payment voucher linked to the payment row it made
(stage-4 item 2, LINK-001; measured 3 Oct 2026, again on the 11 Oct backup).

Manual payment vouchers to 14 Sep 2026 named a supplier purchase and left its
payment row unlinked (InvoicePayment.source_voucher_id NULL): the cash is
counted, the link is missing. Linking moves no amount -- a voucher that is not
cancelled counts as it did (payment_voucher_not_cancelled) -- and gives what
the link is for: a later cancellation of the voucher drops its payment, the
retraction guard names the voucher, a re-approval adds no second row.

Only a one-to-one match is linked: an approved payment voucher on a purchase
from a supplier with no row linked to it, and exactly one unlinked payment row
of its amount on that invoice that no other such voucher matches. Anything
else is said, not guessed. dry_run (the default) writes nothing.
"""
import json
from collections import defaultdict

from models import AuditLog, Invoice, InvoicePayment, Voucher, db

CENT = 0.005
PURCHASE_TYPES = ('شراء',)


def link_payment_vouchers(*, by: str, dry_run: bool = True, invoice_ids=None) -> dict:
    vouchers = (Voucher.query.join(Invoice, Invoice.id == Voucher.reference_id)
                .filter(Voucher.reference_type == 'invoice', Voucher.voucher_type == 'payment',
                        Voucher.status == 'approved', Invoice.invoice_type.in_(PURCHASE_TYPES)))
    if invoice_ids is not None:
        vouchers = vouchers.filter(Voucher.reference_id.in_(list(invoice_ids)))
    linked_ids = {i for (i,) in db.session.query(InvoicePayment.source_voucher_id)
                  .filter(InvoicePayment.source_voucher_id.isnot(None)).all()}

    candidates = {}
    claims = defaultdict(list)
    for v in vouchers.order_by(Voucher.id).all():
        if v.id in linked_ids:
            continue
        amount = float(v.amount_cash or 0.0)
        rows = [p for p in InvoicePayment.query.filter_by(invoice_id=v.reference_id, source_voucher_id=None)
                if abs(float(p.amount or 0.0) - amount) < CENT]
        candidates[v.id] = (v, rows)
        for p in rows:
            claims[p.id].append(v.id)

    linked, ambiguous, unmatched = [], [], []
    for vid, (v, rows) in candidates.items():
        if not rows:
            unmatched.append({'voucher': v.voucher_number, 'invoice_id': v.reference_id,
                              'amount': float(v.amount_cash or 0.0)})
            continue
        if len(rows) != 1 or len(claims[rows[0].id]) != 1:
            ambiguous.append({'voucher': v.voucher_number, 'invoice_id': v.reference_id,
                              'rows': [p.id for p in rows], 'vouchers_for_them': sorted({x for p in rows
                                                                                          for x in claims[p.id]})})
            continue
        linked.append({'voucher_id': v.id, 'voucher': v.voucher_number, 'invoice_id': v.reference_id,
                       'payment_id': rows[0].id, 'amount': round(float(v.amount_cash or 0.0), 2)})
        if not dry_run:
            rows[0].source_voucher_id = v.id

    plan = {'linked': linked, 'count': len(linked), 'amount': round(sum(l['amount'] for l in linked), 2),
            'ambiguous': ambiguous, 'unmatched': len(unmatched)}
    if linked and not dry_run:
        db.session.flush()
        db.session.add(AuditLog(user_name=by, action='stage4_payment_voucher_links', entity_type='invoice_payment',
                                entity_id=linked[0]['payment_id'], success=True,
                                details=json.dumps({k: plan[k] for k in ('linked', 'count', 'amount')},
                                                   ensure_ascii=False, default=str)))
        db.session.flush()
    return plan
