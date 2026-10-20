"""Rejecting an unposted invoice -- the one way, for the reject route and the undoing of an execution.

It was the body of `/invoices/<id>/reject`. An office reservation's execution
now approves its purchase at once (ADR-052, the owner 19 Oct 2026), so its
undoing -- «إلغاء التنفيذ» -- unposts the invoice by the one unposting and then
rejects it by this same body: one undoing, not a second.

In order: the reservation's settlement reversed (its gold entry, the deposit's
payment row, the voucher's tag -- Phase 8E) and the reservation reopened; the
invoice's own draft payments withdrawn; refused while a real payment stands,
or a weight-closing execution consumed it; its closing order withdrawn, its
gold evidence released, its entries drafts, its approval alert answered.

Returns {'refusal': {...}} -- the caller rolls back and answers 409 -- or
{'reservation': the reopened reservation or None, 'withdrawn': [...]}. The
caller marks the invoice rejected, writes the audit row and commits.
"""
from __future__ import annotations

from models import JournalEntry, OfficeReservation, db


def reject_invoice_document(invoice, *, by, now) -> dict:
    """*now*: the run's clock, passed in (ADR-015)."""
    from routes.office_reservations import reverse_office_reservation_settlement_for_invoice
    from services.invoice_retraction_guard import (
        closing_executions_message, closing_executions_of, draft_payments_of, live_payments_message,
        live_payments_of, withdraw_closing_order,
    )
    from services.gold_allocation_service import release_invoice_gold_evidence
    from models import SystemAlert

    invoice_id = invoice.id

    # The settlement's accounting undone first (the gold entry, the weight
    # closing it consumed, the deposit voucher's link) -- before the
    # reservation lets go of the invoice, by which this finds it.
    reverse_office_reservation_settlement_for_invoice(invoice, created_by=by)

    # The reservation open again as it was made: 'approved', none of its
    # weight consumed -- it was left «pending» with all of it read as consumed
    # (the voucher screen review, 20 Oct 2026; the pending weight read short).
    reservation = OfficeReservation.query.filter_by(purchase_invoice_id=invoice_id).first()
    if reservation:
        reservation.purchase_invoice_id = None
        reservation.status = 'approved'
        reservation.weight_consumed_main_karat = 0.0
        reservation.weight_remaining_main_karat = float(reservation.weight_main_karat or 0.0)
        reservation.executions_created = 0
        db.session.add(reservation)

    # Asked after the reversal above: it deletes the deposit's InvoicePayment and
    # retags the deposit voucher itself (Phase 8E), so what remains is exactly
    # what rejecting would leave dangling. An unposted invoice's own payments --
    # no voucher, no safe-box row -- are part of its draft and go with it
    # (ADR-034; RETRACT-001, the owner's decision of 1 Oct 2026).
    db.session.flush()
    withdrawn = [{'payment_id': p.id, 'amount': float(p.amount or 0),
                  'payment_method_id': p.payment_method_id} for p in draft_payments_of(invoice)]
    for p in draft_payments_of(invoice):
        db.session.delete(p)
    db.session.flush()
    standing = live_payments_of(invoice_id)
    if standing:
        return {'refusal': {'error': 'has_live_payments', 'message': live_payments_message('رفض', standing),
                            'payments': standing}}

    # Rejected 2821, 3123 and 3303 kept their closing orders open -- 5,706 g
    # waiting to take real purchases for sales that never were.
    closed = closing_executions_of(invoice_id)
    if closed > 0:
        return {'refusal': {'error': 'has_closing_executions',
                            'message': closing_executions_message('رفض', closed)}}
    withdraw_closing_order(invoice)

    # The gold evidence: attributions go (the gold was delivered and its voucher
    # stays, but its claim on this invoice is no longer true), allocations are
    # released, the obligation rows stay -- ADR-028's fixed record.
    release_invoice_gold_evidence(invoice_id)

    # A rejected invoice is an unposted one: its entries stay drafts and count
    # nowhere (ADR-034), and its approval alert is answered.
    for je in JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id).all():
        je.is_posted = False
        je.is_draft = True
    SystemAlert.query.filter_by(entity_type='Invoice', entity_id=invoice_id, is_reviewed=False).update(
        {'is_reviewed': True, 'reviewed_by': by, 'reviewed_at': now}, synchronize_session=False)
    if withdrawn:
        from services.invoice_payment_state_service import InvoicePaymentStateService
        InvoicePaymentStateService().recompute(invoice)
    return {'reservation': reservation, 'withdrawn': withdrawn}
