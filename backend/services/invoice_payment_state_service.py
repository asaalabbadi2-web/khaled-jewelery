"""invoice_payment_state_service.py — the single writer for Invoice.amount_paid
and Invoice.status.

WHY THIS EXISTS
    Before this service, four call sites each recomputed these two fields with
    their own formula:
        - approve_invoice           : invoice.amount_paid + barter_total
        - add_invoice_payment       : incremental (paid_amount + this payment)
        - add_invoice (two branches): same formula as approve_invoice, on a
                                       not-yet-persisted invoice
        - approve_large_discount_invoice : SUM(InvoicePayment.amount) directly

    None of those four is reachable from routes/vouchers.py — so a payment
    recorded through the general voucher endpoints (create_voucher,
    approve_voucher) or reversed through cancel_voucher never touched either
    field, regardless of the voucher's reference_type. That gap is what this
    service closes: it becomes the fifth caller, wired into the voucher
    lifecycle too, and the only formula.

SINGLE SOURCE OF TRUTH
    SUM(InvoicePayment.amount) for this invoice, plus barter_total — excluding
    any InvoicePayment whose source_voucher_id points at a cancelled voucher.
    Not invoice.amount_paid itself (that would be circular — the column being
    recomputed cannot be its own input) and not a running increment (that is
    what let amount_paid and the real InvoicePayment rows drift apart in
    production).

WHAT amount_paid IS COMPARED AGAINST (Phase 13)
    invoice.cash_obligation (models.py), not invoice.total — for every
    invoice_type except 'شراء' the two are identical, so this only changes
    anything for registered-supplier purchases. Invoice.total there also
    carries the raw gold value itself, which is a barter/inventory concept
    and never a cash debt on the supplier (routes/invoices.py's own "ليست
    التزامًا على المورد" comment on the memo-account gold posting) — see the
    invoice-payment audit's Phase 12A-12C. amount_paid itself is untouched by
    this: it still only ever counts real InvoicePayment rows.

CANCELLATION IS EXCLUDED BY A DIRECT FK, NEVER BY DELETING THE ROW
    cancel_voucher (routes/vouchers.py) reverses the JournalEntry and
    SafeBoxTransaction for a payment voucher but has never touched
    InvoicePayment — and this service does not change that. Deleting the
    InvoicePayment on cancel was considered and rejected: it would destroy
    the historical record of what was recorded, when, and how, for an event
    (cancellation) that is itself worth keeping visible. Fabricating the
    payment_method_id a synthetic InvoicePayment would need for a voucher
    that never had one was rejected for the same reason every other guess
    was rejected in this codebase: it is not known, so it is not invented.

    So a cancelled payment's own InvoicePayment row survives, and is excluded
    from the sum instead, via InvoicePayment.source_voucher_id — a real FK,
    populated only by the three paths that actually create a payment
    (add_invoice_payment; add_invoice's two payment branches).

    This used to be inferred through SafeBoxTransaction.ref_id, which turned
    out not to be reliable: some code paths write ref_id=voucher.id, the
    payment-method-correction paths write ref_id=invoice_payment.id instead,
    and the two id spaces can coincide by pure numeric accident. A real
    example was found in a restored production copy — SafeBoxTransaction
    ref_id=444 meant "InvoicePayment #444" under the old convention, while an
    unrelated Voucher #444 genuinely exists for a different invoice entirely.
    Cancelling that voucher would have excluded the wrong payment. This
    service no longer reads SafeBoxTransaction or Voucher at all to decide
    what to exclude — only InvoicePayment.source_voucher_id and the
    referenced Voucher's own status.

    - A payment recorded through the three receipt-creating paths carries
      source_voucher_id, so cancelling its voucher is picked up correctly and
      unambiguously.
    - A payment recorded through a DEFERRED/receivable payment method still
      gets source_voucher_id set the same way (the column is populated at
      InvoicePayment creation, independent of whether a SafeBoxTransaction
      exists) — but routes/invoices.py's _create_deferred_payment_entries
      never creates a voucher for it in the first place ("دفع آجل: لا حركة
      خزينة"), so there is no voucher to cancel and nothing to exclude by. A
      NULL source_voucher_id is also possible for legacy rows predating this
      column. This is the same gap the audit already named UNKNOWN — NO
      RELIABLE DIRECT LINK; it is not solved here.
    - A row produced by payment-method correction/split
      (_correct_invoice_payment_method_multi_split,
      correct_invoice_payment_method) keeps source_voucher_id = NULL on
      purpose — that reclassification voucher did not create the payment, it
      only recategorised money already received, so its cancellation must
      never reduce what the invoice shows as paid.

WHAT THIS SERVICE DOES NOT DO
    - It does not create, delete, or reverse InvoicePayment, Voucher, or
      JournalEntry rows. It only reads InvoicePayment and writes two columns
      on Invoice. Every caller still owns its own accounting effect and its
      own commit.
    - It does not decide eligibility, direction, or amounts. It is purely a
      projection: given the payments that exist right now, what should the
      invoice's cached fields say?

THE 'rejected' GUARD
    Invoice.status is overloaded: reject_invoice() writes 'rejected' into the
    same column that otherwise carries a payment state. Untangling that is a
    separate, deliberately deferred decision. Until it is made, recompute()
    must not silently overwrite a rejection — doing so would let an unrelated
    payment write erase a workflow decision no caller here is aware of. So a
    'rejected' invoice is left untouched; the caller gets no error, because
    callers do not currently expect one.
"""
from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import func

from models import Invoice, InvoicePayment, Voucher, db

CASH_EPSILON = 0.01

# Weight tolerance, matching gold_allocation_service.WEIGHT_EPSILON so the two
# modules cannot disagree about whether an obligation is closed.
GOLD_EPSILON = 0.005


@dataclass(frozen=True)
class InvoicePaymentState:
    """What recompute() decided, so a caller can log or assert on it without
    re-deriving it from the invoice object afterward."""
    invoice_id: int
    total: float
    obligation_ceiling: float
    amount_paid: float
    status: str
    changed: bool
    # The gold dimension, None when this invoice's gold is UNTRACKED (every
    # invoice predating Phase A). None means "not part of the status decision",
    # never "nothing settled".
    gold_required_main_karat: float = None
    gold_attributed_main_karat: float = None


class InvoicePaymentStateService:
    """Usage:

        InvoicePaymentStateService().recompute(invoice)
        # invoice.amount_paid and invoice.status are now correct.
        # The caller still commits.
    """

    def recompute(self, invoice: Invoice) -> InvoicePaymentState:
        if invoice.status == 'rejected':
            return InvoicePaymentState(
                invoice_id=int(invoice.id),
                total=float(invoice.total or 0.0),
                obligation_ceiling=float(invoice.cash_obligation),
                amount_paid=float(invoice.amount_paid or 0.0),
                status=invoice.status,
                changed=False,
            )

        total = float(invoice.total or 0.0)
        obligation_ceiling = float(invoice.cash_obligation)
        paid = self._sum_invoice_payments(invoice.id)
        barter = float(getattr(invoice, 'barter_total', 0.0) or 0.0)
        total_settled = round(paid + barter, 2)

        before = (
            round(float(invoice.amount_paid or 0.0), 2),
            invoice.status,
        )

        gold_required, gold_settled = self._gold_dimension(invoice)

        # amount_paid stays CASH ONLY — it is a currency field, and the gold
        # dimension has its own quantities rather than being folded into it.
        invoice.amount_paid = total_settled
        invoice.status = self._status_for(
            total=obligation_ceiling,
            total_settled=total_settled,
            gold_required=gold_required,
            gold_settled=gold_settled,
        )

        after = (total_settled, invoice.status)

        return InvoicePaymentState(
            invoice_id=int(invoice.id),
            total=total,
            obligation_ceiling=obligation_ceiling,
            amount_paid=total_settled,
            status=invoice.status,
            changed=(before != after),
            gold_required_main_karat=gold_required,
            gold_attributed_main_karat=gold_settled,
        )

    @staticmethod
    def _sum_invoice_payments(invoice_id: int) -> float:
        """SUM(InvoicePayment.amount), excluding payments whose creating
        voucher was cancelled — see the class docstring for why this is a
        direct FK now, not a join through SafeBoxTransaction, and where it
        still cannot see a cancellation (source_voucher_id NULL: deferred
        payments with no voucher at all, and legacy rows predating this
        column)."""
        total = (
            db.session.query(func.coalesce(func.sum(InvoicePayment.amount), 0.0))
            .outerjoin(Voucher, Voucher.id == InvoicePayment.source_voucher_id)
            .filter(
                InvoicePayment.invoice_id == invoice_id,
                db.or_(
                    InvoicePayment.source_voucher_id.is_(None),
                    Voucher.status != 'cancelled',
                ),
            )
            .scalar()
        )
        return round(float(total or 0.0), 2)

    @staticmethod
    def _status_for(
        *,
        total: float,
        total_settled: float,
        gold_required: float = None,
        gold_settled: float = None,
    ) -> str:
        """The invoice's status from BOTH obligations.

        `gold_required is None` means this invoice's gold is UNTRACKED, and the
        answer is then exactly what it has always been — cash alone. That is
        what keeps every invoice predating Phase A bit-for-bit unchanged.

        When gold IS tracked, 'paid' requires both sides. A purchase invoice can
        owe 5,000 SAR and 200 g; paying the cash and 120 g of the gold leaves it
        partially paid with 80 g outstanding, and calling that 'paid' because the
        cash cleared would be the same half-truth this whole audit began with.
        """
        cash_touched = total_settled > CASH_EPSILON

        if gold_required is None:
            if total <= CASH_EPSILON:
                # Zero-total invoices: any settlement at all counts as paid.
                return 'paid' if cash_touched else 'unpaid'
            if not cash_touched:
                return 'unpaid'
            return 'paid' if total_settled >= total - CASH_EPSILON else 'partially_paid'

        # A zero CASH obligation is SATISFIED, not merely untouched. This is a
        # real shape, not a corner case: Phase 13 gives a purchase invoice a
        # cash_obligation of 0 when the supplier's wage is paid in gold
        # (default_wage_type='gold'), so its entire obligation is the gold. The
        # legacy zero-total rule above ("paid only if something was paid")
        # belongs to a cash-only world; applied here it would hold such an
        # invoice at partially_paid forever with its gold fully settled.
        cash_paid = total <= CASH_EPSILON or total_settled >= total - CASH_EPSILON

        gold_required = float(gold_required or 0.0)
        gold_settled = float(gold_settled or 0.0)
        # No gold obligation at all: the gold side is vacuously satisfied and
        # must not drag an otherwise paid invoice down to partial.
        gold_paid = gold_required <= GOLD_EPSILON or gold_settled >= gold_required - GOLD_EPSILON
        gold_touched = gold_settled > GOLD_EPSILON

        if total <= CASH_EPSILON and gold_required <= GOLD_EPSILON:
            return 'paid' if (cash_touched or gold_touched) else 'unpaid'
        if cash_paid and gold_paid:
            return 'paid'
        if not cash_touched and not gold_touched:
            return 'unpaid'
        return 'partially_paid'

    @staticmethod
    def _gold_dimension(invoice):
        """(required, attributed) in main-karat-equivalent, or (None, None) when
        this invoice's gold is untracked.

        Imported lazily: invoice_payment_state_service is imported very early and
        gold_allocation_service imports models that would close the cycle.
        """
        if not getattr(invoice, 'gold_settlement_tracked', False):
            return None, None
        try:
            from services.gold_allocation_service import (
                direct_linked_settlement_for_invoice,
                obligation_attributed_remaining,
            )
            from models import InvoiceGoldObligation
            from pricing.karat_service import convert_to_main_karat

            obligations = InvoiceGoldObligation.query.filter_by(
                invoice_id=invoice.id
            ).all()
            required = sum(
                float(convert_to_main_karat(float(o.weight or 0.0), o.karat))
                for o in obligations
            )
            remaining = sum(obligation_attributed_remaining(o) for o in obligations)
            return round(required, 2), round(required - remaining, 2)
        except Exception as exc:
            # A tracked invoice whose gold cannot be read must NOT silently
            # become cash-only — that would quietly re-introduce the half-truth.
            raise


def sync_invoice_payment_state_after_voucher_approval(voucher) -> None:
    """Best-effort: recompute the linked invoice's payment state right after
    a voucher is approved.

    Every real payment-creating path (add_invoice_payment; add_invoice's two
    payment branches, in routes/invoices.py) already keeps
    Invoice.amount_paid/status current the moment the payment is recorded,
    because each of them self-approves the voucher it creates inline in the
    same request. This call is a no-op for all of those — recompute() finds
    nothing new.

    It only changes anything for the one shape those paths never produce
    today: an InvoicePayment whose source_voucher_id points at a voucher
    that was still 'pending' when the payment row was written, reaching
    'approved' only later, here. Extracted so every approval implementation
    that can move a voucher into 'approved' calls it the same way, instead
    of only whichever one happened to be patched first.

    Deliberately swallows its own failure instead of raising: by the time
    this runs, the caller has already posted real accounting (JournalEntry
    and/or SafeBoxTransaction rows) for this voucher, and none of its
    callers are written to roll that back for a stale-cache failure
    downstream of it. Whether a failed recompute should instead abort the
    whole approval is an accounting/business call this function does not
    make — see the Phase 5 report's open decisions.
    """
    if voucher.reference_type == 'invoice' and voucher.reference_id:
        try:
            linked_invoice = Invoice.query.get(int(voucher.reference_id))
            if linked_invoice is not None:
                InvoicePaymentStateService().recompute(linked_invoice)
        except Exception as _sync_exc:
            print(f"⚠️ invoice payment-state sync after voucher approve skipped: {_sync_exc}")
