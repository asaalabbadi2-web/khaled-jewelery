"""Undo what still counts for a rejected invoice -- by entries, never by editing a posted row (stage 4).

On 28 Sep 2026 a settings save posted every unposted entry, rejected invoices'
too (SETTINGS-001, fixed that day): 2821's entry moved 5,700 g of 21k out of
display inventory, 5,700 of sales and 102,600 of wages; 3123's -- a duplicate,
re-entered as 3124 -- counted a sale twice. Both stay rejected. ADR-034: a
rejected invoice has no financial effect anywhere.

The owner (3 Oct 2026): each posted entry gets a posted reversing entry dated
as the original, so August and September read right. In one transaction:

- every posted entry of the invoice (and of its payments) without a posted
  reversal gets one: 'journal_entry_reversal' -> the original's id, lines
  mirrored on every column (services/repair/entries.py);
- its unposted entries become drafts -- a rejected invoice's entries are
  drafts (ADR-034);
- its own safe-box rows go, as unposting removes them, and its payments' rows;
- its pending vouchers are rejected, their entry link dropped (the entry stays
  a draft), and its payments withdrawn -- a rejected voucher pays nothing;
- one audit row names everything it did.

dry_run (the default) computes the same and writes nothing. Idempotent: a
second run finds nothing to do.
"""
import json

from models import AuditLog, Invoice, InvoicePayment, JournalEntry, SafeBoxTransaction, Voucher, db
from services.repair.entries import reverse_entry, reversed_already


class NotARejectedInvoice(ValueError):
    pass


def reverse_rejected_invoice(invoice_id: int, *, by: str, reason: str, dry_run: bool = True) -> dict:
    from services.invoice_retraction_guard import OWN_MOVEMENT_TYPES
    invoice = db.session.get(Invoice, int(invoice_id))
    if invoice is None or invoice.status != 'rejected' or invoice.is_posted:
        raise NotARejectedInvoice(f'invoice {invoice_id} is not a rejected, unposted invoice')

    payments = InvoicePayment.query.filter_by(invoice_id=invoice.id).all()
    payment_ids = [p.id for p in payments]
    entries = JournalEntry.query.filter(
        JournalEntry.is_deleted.is_(False),
        db.or_(
            db.and_(JournalEntry.reference_type.in_(['invoice', 'invoice_payments']),
                    JournalEntry.reference_id == invoice.id),
            db.and_(JournalEntry.reference_type == 'invoice_payment',
                    JournalEntry.reference_id.in_(payment_ids or [-1])),
        )).all()
    to_reverse = [e for e in entries if e.is_posted and not reversed_already(e.id)]
    to_draft = [e for e in entries if not e.is_posted and not e.is_draft]
    vouchers = Voucher.query.filter_by(reference_type='invoice', reference_id=invoice.id, status='pending').all()
    rows = SafeBoxTransaction.query.filter(
        SafeBoxTransaction.invoice_id == invoice.id,
        db.or_(SafeBoxTransaction.ref_type.in_(list(OWN_MOVEMENT_TYPES)),
               SafeBoxTransaction.ref_type == 'invoice_payment')).all()

    plan = {
        'invoice_id': invoice.id, 'invoice_number': invoice.invoice_type_id,
        'reverse_entries': [e.entry_number for e in to_reverse],
        'draft_entries': [e.entry_number for e in to_draft],
        'reject_vouchers': [v.voucher_number for v in vouchers],
        'withdraw_payments': [round(float(p.amount or 0.0), 2) for p in payments],
        'remove_safe_rows': [f'{r.ref_type}/{r.direction}/{r.safe_box_id}' for r in rows],
    }
    if dry_run or not (to_reverse or to_draft or vouchers or payments or rows):
        plan['written'] = False
        return plan

    # Its safe rows go below, as unposting removes them: the reversal writes none.
    reversals = [reverse_entry(e, by=by, reason=reason) for e in to_reverse]
    for e in to_draft:
        e.is_draft = True
    for v in vouchers:
        v.status = 'rejected'
        v.journal_entry_id = None
        v.rejection_reason = reason
    for r in rows:
        db.session.delete(r)
    for p in payments:
        db.session.delete(p)
    db.session.flush()
    plan['reversal_entries'] = [r.entry_number for r in reversals]
    plan['written'] = True
    AuditLog.log_action(user_name=by, action='stage4_reverse_rejected_invoice', entity_type='Invoice',
                        entity_id=invoice.id, entity_number=str(invoice.invoice_type_id),
                        details=json.dumps(dict(plan, reason=reason), ensure_ascii=False))
    return plan
