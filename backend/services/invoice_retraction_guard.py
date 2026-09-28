"""What must be true before an invoice may be rejected, unposted or deleted.

A payment is an event that happened. Retracting the document it was linked to
does not un-happen it -- yet every retraction path used to take the payment
with it: rejecting 3123 left its Mada receipt to be settled as if live,
deleting 3132 destroyed a real gold payment and orphaned a reversal JE that
doubled the supplier's balance (2026-09-26/27), and unposting then re-posting
1641, 1779, 2204 and 2478 left 92,385.00 of posted receipts reading as zero in
the safe-box statements (May-July, measured 2026-09-28).

Two questions, answered here once and asked by every retraction path:

  live_payments_of(invoice_id)
      Payments still standing against the invoice. Rejecting and unposting
      are refused while any remains: cancel it, or move its attribution to the
      invoice that replaces this one.

  financial_history_of(invoice_id)
      Every row some OTHER document or process wrote about the invoice --
      payments (cancelled included), attributions, returns, closings, bonuses,
      reconciliation rows. Deleting is refused while any exists: a document
      with history is rejected, not deleted, so its trail stays auditable.

REFERENCES below is the classification delete relies on. Every foreign key
into an invoice, or into a row the invoice owns, must appear in it --
tests/test_invoice_retraction_guard.py::TestEveryReferenceIsClassified fails
otherwise. Delete used to carry its own checklist of tables to clear ("a future
table added to Invoice belongs here too"), so a table nobody remembered was a
table delete destroyed, or crashed on by luck. Now a table nobody classified
fails the build, and one classified as evidence makes delete refuse.
"""
from __future__ import annotations

import sqlalchemy as sa
from sqlalchemy import or_

from models import InvoicePayment, SafeBoxTransaction, Voucher, VoucherInvoiceGoldAttribution, db
from services.invoice_payment_state_service import payment_voucher_not_cancelled

OWNED = 'owned'
EVIDENCE = 'evidence'

# (table, column) -> (the table that column points at, who wrote the row).
#   OWNED     the invoice itself wrote it, at creation or posting; delete removes it.
#   EVIDENCE  another document or process wrote it; delete refuses while one exists.
# When unsure, it is EVIDENCE: refusing a delete costs a rejection instead,
# destroying a row costs the record that something happened.
REFERENCES = {
    ('invoice_item', 'invoice_id'): ('invoice', OWNED),
    ('invoice_karat_line', 'invoice_id'): ('invoice', OWNED),
    ('category_weight_movement', 'invoice_id'): ('invoice', OWNED),  # manual ones carry no invoice
    ('invoice_gold_obligation', 'invoice_id'): ('invoice', OWNED),
    ('invoice_weight_settlement', 'invoice_id'): ('invoice', OWNED),
    ('weight_closing_order', 'invoice_id'): ('invoice', OWNED),
    # Only the movement types in OWN_MOVEMENT_TYPES; any other row carrying the
    # invoice's id was written by something else and counts as evidence.
    ('safe_box_transaction', 'invoice_id'): ('invoice', OWNED),

    ('invoice_payment', 'invoice_id'): ('invoice', EVIDENCE),
    ('voucher_invoice_gold_attribution', 'invoice_id'): ('invoice', EVIDENCE),
    ('invoice', 'original_invoice_id'): ('invoice', EVIDENCE),       # a return of it
    ('invoice', 'barter_sale_invoice_id'): ('invoice', EVIDENCE),    # the other half of a barter
    ('office_reservation', 'purchase_invoice_id'): ('invoice', EVIDENCE),
    ('weight_closing_execution', 'source_invoice_id'): ('invoice', EVIDENCE),
    ('bonus_invoice_link', 'invoice_id'): ('invoice', EVIDENCE),
    ('bonus_clawback_candidate', 'original_invoice_id'): ('invoice', EVIDENCE),
    ('bonus_clawback_candidate', 'return_invoice_id'): ('invoice', EVIDENCE),
    ('supplier_gold_transaction', 'invoice_id'): ('invoice', EVIDENCE),
    # Written against rows the invoice owns.
    ('gold_allocation', 'obligation_id'): ('invoice_gold_obligation', EVIDENCE),
    ('weight_closing_execution', 'order_id'): ('weight_closing_order', EVIDENCE),
    ('weight_closing_log', 'sale_item_id'): ('invoice_item', EVIDENCE),
    ('historical_clearing_adjustment', 'safe_box_transaction_id'): ('safe_box_transaction', EVIDENCE),
}

# The safe-box movements an invoice writes about itself: the sale movement at
# creation, the scrap provisional rows, the posting/unposting pair, and the rows
# accounting/safe_boxes._ensure_safe_box_transactions_for_invoice_je derives
# from the invoice's own journal lines ('invoice').
OWN_MOVEMENT_TYPES = (
    'invoice',
    'invoice_sale_gold_movement',
    'invoice_scrap_receipt',
    'invoice_scrap_return',
    'invoice_scrap_sale',
    'invoice_gold',
    'invoice_gold_reversal',
)

_EVIDENCE_NAMES = {
    ('invoice', 'original_invoice_id'): 'فاتورة مرتجع',
    ('invoice', 'barter_sale_invoice_id'): 'فاتورة مقايضة',
    ('office_reservation', 'purchase_invoice_id'): 'حجز مكتب',
    ('weight_closing_execution', 'source_invoice_id'): 'تنفيذ تسكير',
    ('bonus_invoice_link', 'invoice_id'): 'مكافأة موظف',
    ('bonus_clawback_candidate', 'original_invoice_id'): 'استرداد مكافأة',
    ('bonus_clawback_candidate', 'return_invoice_id'): 'استرداد مكافأة',
    ('supplier_gold_transaction', 'invoice_id'): 'حركة ذهب مورد',
    ('gold_allocation', 'obligation_id'): 'تخصيص سلفة ذهب',
    ('weight_closing_execution', 'order_id'): 'تنفيذ تسكير',
    ('weight_closing_log', 'sale_item_id'): 'سجل تسكير',
    ('historical_clearing_adjustment', 'safe_box_transaction_id'): 'تسوية مقاصة تاريخية',
}


def _owned_tables() -> dict[str, str]:
    """Owned table -> the column through which the invoice owns it."""
    return {table: column for (table, column), (parent, kind) in REFERENCES.items()
            if kind == OWNED and parent == 'invoice'}


def _declared_references(metadata) -> set[tuple[str, str]]:
    watched = {'invoice'} | set(_owned_tables())
    return {
        (table.name, fk.parent.name)
        for table in metadata.tables.values()
        for fk in table.foreign_keys
        if fk.target_fullname.split('.')[-2] in watched
    }


def unclassified_references(metadata) -> set[tuple[str, str]]:
    """Foreign keys into an invoice, or into a row it owns, that REFERENCES
    does not classify."""
    return _declared_references(metadata) - set(REFERENCES)


def stale_references(metadata) -> set[tuple[str, str]]:
    """Classifications naming a foreign key the models no longer declare."""
    return set(REFERENCES) - _declared_references(metadata)


def _label(voucher: Voucher | None, payment: InvoicePayment | None = None) -> str:
    if voucher is not None:
        return voucher.voucher_number or f'سند #{voucher.id}'
    return f'دفعة #{payment.id}'


def live_payments_of(invoice_id: int) -> list[str]:
    """Labels of the payments still standing against *invoice_id*.

    A linked voucher stands unless it was cancelled -- a NULL status has not
    been shown cancelled, so it stands (none exist in production; this only
    decides which side an unknown falls on). An InvoicePayment stands by the
    rule InvoicePaymentStateService already applies, reused: its creating
    voucher was not cancelled, or it has none. A voucher whose gold is
    attributed to the invoice stands too: an independent payment names no
    invoice in its reference_type, and the attribution row is the only
    evidence of whom it paid. Cancelling a voucher removes its attributions
    (remove_attributions_for_voucher), so a cancelled one never reaches here.
    """
    labels: list[str] = []
    seen: set[int] = set()

    def _add_voucher(v: Voucher) -> None:
        if v.id not in seen:
            labels.append(_label(v))
            seen.add(v.id)

    for v in (Voucher.query
              .filter(Voucher.reference_type == 'invoice',
                      Voucher.reference_id == invoice_id,
                      or_(Voucher.status.is_(None), Voucher.status != 'cancelled'))
              .order_by(Voucher.id).all()):
        _add_voucher(v)

    payments = (
        InvoicePayment.query
        .outerjoin(Voucher, Voucher.id == InvoicePayment.source_voucher_id)
        .filter(InvoicePayment.invoice_id == invoice_id, payment_voucher_not_cancelled())
        .order_by(InvoicePayment.id)
        .all()
    )
    for ip in payments:
        if ip.source_voucher_id in seen:
            continue
        v = Voucher.query.get(ip.source_voucher_id) if ip.source_voucher_id else None
        if v is not None:
            _add_voucher(v)
        else:
            labels.append(_label(None, ip))

    for v in (Voucher.query
              .join(VoucherInvoiceGoldAttribution, VoucherInvoiceGoldAttribution.voucher_id == Voucher.id)
              .filter(VoucherInvoiceGoldAttribution.invoice_id == invoice_id,
                      or_(Voucher.status.is_(None), Voucher.status != 'cancelled'))
              .order_by(Voucher.id).all()):
        _add_voucher(v)
    return labels


def live_payments_message(action: str, labels: list[str]) -> str:
    """The one wording for "refused: a payment stands", for every path."""
    return (
        f'لا يمكن {action} فاتورة عليها سداد قائم: ' + '، '.join(labels) + '. '
        'ألغِ السداد أولًا، أو انقل نسبته إلى الفاتورة الصحيحة، ثم أعد المحاولة.'
    )


def _payment_history(invoice_id: int) -> list[str]:
    labels: list[str] = []
    seen: set[int] = set()
    for v in (Voucher.query
              .filter(Voucher.reference_type == 'invoice', Voucher.reference_id == invoice_id)
              .order_by(Voucher.id).all()):
        labels.append(_label(v))
        seen.add(v.id)
    for ip in InvoicePayment.query.filter_by(invoice_id=invoice_id).order_by(InvoicePayment.id).all():
        if ip.source_voucher_id in seen:
            continue
        v = Voucher.query.get(ip.source_voucher_id) if ip.source_voucher_id else None
        labels.append(_label(v, ip))
        if v is not None:
            seen.add(v.id)
    for v in (Voucher.query
              .join(VoucherInvoiceGoldAttribution, VoucherInvoiceGoldAttribution.voucher_id == Voucher.id)
              .filter(VoucherInvoiceGoldAttribution.invoice_id == invoice_id)
              .order_by(Voucher.id).all()):
        if v.id not in seen:
            labels.append(_label(v))
            seen.add(v.id)
    return labels


def financial_history_of(invoice_id: int) -> list[str]:
    """Labels of every row another document or process wrote about
    *invoice_id*, cancelled payments included."""
    labels = _payment_history(invoice_id)
    handled = {('invoice_payment', 'invoice_id'), ('voucher_invoice_gold_attribution', 'invoice_id')}
    meta = db.Model.metadata
    owners = _owned_tables()

    for (table, column), (parent, kind) in REFERENCES.items():
        if kind != EVIDENCE or (table, column) in handled:
            continue
        child = meta.tables[table]
        key = list(child.primary_key.columns)[0]
        if parent == 'invoice':
            query = sa.select(key).where(child.c[column] == invoice_id)
        else:
            owner = meta.tables[parent]
            query = (sa.select(key)
                     .select_from(child.join(owner, owner.c.id == child.c[column]))
                     .where(owner.c[owners[parent]] == invoice_id))
        for (row_id,) in db.session.execute(query.order_by(key).limit(20)).all():
            labels.append(f'{_EVIDENCE_NAMES[(table, column)]} #{row_id}')

    foreign_rows = SafeBoxTransaction.query.filter(
        SafeBoxTransaction.invoice_id == invoice_id,
        or_(SafeBoxTransaction.ref_type.is_(None),
            SafeBoxTransaction.ref_type.notin_(OWN_MOVEMENT_TYPES)),
    )
    if labels:
        # A payment already named above is not named again through its rows.
        foreign_rows = foreign_rows.filter(or_(
            SafeBoxTransaction.ref_type.is_(None),
            SafeBoxTransaction.ref_type.notin_(('invoice_payment', 'voucher', 'voucher_reversal')),
        ))
    for t in foreign_rows.order_by(SafeBoxTransaction.id).limit(20).all():
        labels.append(f'حركة خزينة ({t.ref_type or "بلا نوع"}) #{t.id}')
    return labels
