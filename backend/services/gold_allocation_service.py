"""gold_allocation_service.py — Single Writer for GoldAllocation.

Phase 15B/15A-Correction of the invoice-payment audit's Gold Advance &
Allocation arc. Mirrors allocation_service.py's AllocationService SHAPE
deliberately (Plan building -> Allocate -> Unallocate), not its table:
SAR+InvoicePayment and weight+karat+InvoiceGoldObligation/SupplierGoldAdvance
are genuinely different domains (Phase 14's own "share the shape, not the
table" decision).

KARAT RULE (Phase 14, proven via the real karat_diff_* mechanism in
posting_routes.py): SupplierGoldAdvance.karat/weight and
InvoiceGoldObligation.karat/weight are each the REAL karat an event actually
happened in — never converted, never touched here. Only the running BALANCE
columns (weight_remaining_main_karat, on both sides) are main-karat-
equivalent, because comparing/subtracting across differing karats is only
possible in a common unit. Every read/write in the allocation engine below
touches ONLY the balance columns — it never reads or writes karat/weight.

SCOPE (see the Phase 15 sub-phase plan in project memory):
    This service does the matching/bookkeeping only. It does NOT:
    - Create Vouchers, VoucherAccountLines, or JournalEntries.
    - Post a karat-mismatch cash fee. Auto-matching (FIFO) is therefore
      restricted to SAME-KARAT pairs only — an advance can only
      auto-satisfy an obligation in its own real karat. Cross-karat
      settlement (what the existing karat_diff_* mechanism already handles
      for vouchers, by having a human specify the fee up front) is left to
      manual_allocate() — a deliberate, explicit human decision (wired from
      a route in Phase 15C), never invented by this service. This is a
      narrower default than "FIFO with karat_diff bridging" would be;
      flagged here rather than silently assumed.
    - Lock rows against concurrent writers. build_plan_for_* and apply_plan
      both re-read current weight_remaining_main_karat rather than trusting
      a stale value, so calling the same auto_allocate_for_* twice in
      sequence is idempotent (the second call finds nothing left and
      allocates nothing) — but true concurrent-transaction safety (e.g. two
      requests racing on the same advance) needs a row lock at the
      transaction boundary, which belongs in Phase 15C/15D where that
      boundary actually exists, not invented speculatively here.

No validate()-before-allocate step, unlike AllocationService: that method
exists there to protect a MANDATORY-full-coverage invariant (a clearing
voucher's gross_amount must be fully absorbed). Gold Allocation has the
opposite invariant by design (Phase 14: "المتبقي من Advance يبقى مفتوحًا" —
partial coverage, with an open remainder, is the normal, expected outcome)
so there is nothing to validate before writing a partial plan.
manual_allocate()'s bounds-checking is inline instead, because it is a
single explicit write, not a multi-line plan that could partially fail.

WHY InvoiceGoldObligation, NOT InvoiceKaratLine (Phase 15A-Correction):
    real 'شراء' purchase invoices record their own gold weight through EITHER
    InvoiceKaratLine (33/180 real invoices) OR InvoiceItem (147/180) — never
    a third way, and the 4 invoices proven to carry both have identical
    per-karat totals in each (duplicates of the same fact, not two
    obligations). InvoiceGoldObligation is the single, source-agnostic
    ledger normalized from whichever one an invoice actually used — the only
    table this module ever matches against. See
    create_gold_obligations_for_invoice's own docstring for the exact
    precedence rule.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from models import (
    db,
    GoldAllocation,
    Invoice,
    InvoiceGoldObligation,
    InvoiceKaratLine,
    Item,
    SupplierGoldAdvance,
    Voucher,
)
from pricing.karat_service import convert_to_main_karat

WEIGHT_EPSILON = 0.005


@dataclass
class GoldAllocationLine:
    """One line of a plan: this much weight (main-karat-equivalent) matches
    this advance to this invoice gold obligation."""
    advance_id: int
    obligation_id: int
    weight_main_karat: float


@dataclass
class GoldAllocationPlan:
    """Result of build_plan_for_*() — pure data, no DB writes."""
    lines: list[GoldAllocationLine] = field(default_factory=list)
    unallocated_remainder: float = 0.0

    @property
    def total_allocated(self) -> float:
        return round(sum(ln.weight_main_karat for ln in self.lines), 2)


class GoldAllocationService:
    """Usage:

        svc = GoldAllocationService()

        # After a new Advance is posted (Phase 15C call site):
        plan = svc.auto_allocate_for_advance(advance)   # plans AND writes

        # After a new purchase invoice's obligations are created
        # (see create_gold_obligations_for_invoice / Phase 15C call site):
        plan = svc.auto_allocate_for_obligation(obligation)

        # Explicit human override (Phase 15C route):
        svc.manual_allocate(advance_id=..., obligation_id=..., weight_main_karat=...)

        # Reversal (Phase 15C call site, on voucher cancel / purchase return):
        svc.unallocate(advance_id=...)             # or obligation_id=..., or both
    """

    # ------------------------------------------------------------------
    # build_plan_for_advance — FIFO, oldest open invoice first
    # ------------------------------------------------------------------

    def build_plan_for_advance(self, advance: SupplierGoldAdvance) -> GoldAllocationPlan:
        """FIFO-match this advance's own remaining weight against open,
        same-karat InvoiceGoldObligation rows for the same supplier, oldest
        invoice (by Invoice.date) first. Pure calculation — no writes.
        """
        remaining = round(float(advance.weight_remaining_main_karat or 0.0), 2)
        if remaining <= WEIGHT_EPSILON:
            return GoldAllocationPlan(lines=[], unallocated_remainder=remaining)

        candidates = (
            InvoiceGoldObligation.query
            .join(Invoice, Invoice.id == InvoiceGoldObligation.invoice_id)
            .filter(
                Invoice.supplier_id == advance.supplier_id,
                Invoice.invoice_type == 'شراء',
                InvoiceGoldObligation.karat == advance.karat,
                InvoiceGoldObligation.weight_remaining_main_karat > WEIGHT_EPSILON,
            )
            .order_by(Invoice.date.asc(), Invoice.id.asc(), InvoiceGoldObligation.id.asc())
            .all()
        )

        lines: list[GoldAllocationLine] = []
        for obligation in candidates:
            if remaining <= WEIGHT_EPSILON:
                break
            available = round(float(obligation.weight_remaining_main_karat or 0.0), 2)
            if available <= WEIGHT_EPSILON:
                continue
            amount = round(min(available, remaining), 2)
            lines.append(GoldAllocationLine(
                advance_id=advance.id,
                obligation_id=obligation.id,
                weight_main_karat=amount,
            ))
            remaining = round(remaining - amount, 2)

        return GoldAllocationPlan(lines=lines, unallocated_remainder=remaining)

    # ------------------------------------------------------------------
    # build_plan_for_obligation — mirror direction
    # ------------------------------------------------------------------

    def build_plan_for_obligation(self, obligation: InvoiceGoldObligation) -> GoldAllocationPlan:
        """FIFO-match this obligation's own remaining weight against open,
        same-karat SupplierGoldAdvance rows for the same supplier, oldest
        advance (by created_at) first. Pure calculation — no writes.
        """
        remaining = round(float(obligation.weight_remaining_main_karat or 0.0), 2)
        if remaining <= WEIGHT_EPSILON:
            return GoldAllocationPlan(lines=[], unallocated_remainder=remaining)

        invoice = Invoice.query.get(obligation.invoice_id)
        if invoice is None or not invoice.supplier_id:
            return GoldAllocationPlan(lines=[], unallocated_remainder=remaining)

        candidates = (
            SupplierGoldAdvance.query
            .filter(
                SupplierGoldAdvance.supplier_id == invoice.supplier_id,
                SupplierGoldAdvance.karat == obligation.karat,
                SupplierGoldAdvance.weight_remaining_main_karat > WEIGHT_EPSILON,
            )
            .order_by(SupplierGoldAdvance.created_at.asc(), SupplierGoldAdvance.id.asc())
            .all()
        )

        lines: list[GoldAllocationLine] = []
        for advance in candidates:
            if remaining <= WEIGHT_EPSILON:
                break
            available = round(float(advance.weight_remaining_main_karat or 0.0), 2)
            if available <= WEIGHT_EPSILON:
                continue
            amount = round(min(available, remaining), 2)
            lines.append(GoldAllocationLine(
                advance_id=advance.id,
                obligation_id=obligation.id,
                weight_main_karat=amount,
            ))
            remaining = round(remaining - amount, 2)

        return GoldAllocationPlan(lines=lines, unallocated_remainder=remaining)

    # ------------------------------------------------------------------
    # apply_plan — CREATE GoldAllocation rows, decrement both balances
    # ------------------------------------------------------------------

    def apply_plan(self, plan: GoldAllocationPlan) -> GoldAllocationPlan:
        """Write GoldAllocation rows for every line in *plan* and decrement
        both sides' cached weight_remaining_main_karat. Append-only.
        Caller commits.
        """
        for line in plan.lines:
            db.session.add(GoldAllocation(
                advance_id=line.advance_id,
                obligation_id=line.obligation_id,
                weight_applied_main_karat=line.weight_main_karat,
            ))
            advance = SupplierGoldAdvance.query.get(line.advance_id)
            obligation = InvoiceGoldObligation.query.get(line.obligation_id)
            advance.weight_remaining_main_karat = round(
                float(advance.weight_remaining_main_karat or 0.0) - line.weight_main_karat, 2
            )
            obligation.weight_remaining_main_karat = round(
                float(obligation.weight_remaining_main_karat or 0.0) - line.weight_main_karat, 2
            )
        db.session.flush()
        return plan

    # ------------------------------------------------------------------
    # auto_allocate_for_* — plan AND apply in one call (the real entry points)
    # ------------------------------------------------------------------

    def auto_allocate_for_advance(self, advance: SupplierGoldAdvance) -> GoldAllocationPlan:
        return self.apply_plan(self.build_plan_for_advance(advance))

    def auto_allocate_for_obligation(self, obligation: InvoiceGoldObligation) -> GoldAllocationPlan:
        return self.apply_plan(self.build_plan_for_obligation(obligation))

    # ------------------------------------------------------------------
    # manual_allocate — explicit human override, bypasses FIFO ordering
    # ------------------------------------------------------------------

    def manual_allocate(
        self,
        *,
        advance_id: int,
        obligation_id: int,
        weight_main_karat: float,
    ) -> GoldAllocation:
        """A human (Phase 15C route) redirects exactly this much of exactly
        this advance to exactly this invoice obligation. Still bounds-checked
        against both sides' real remaining balances — an override can
        change WHICH obligation gets paid, never fabricate weight that
        does not exist on the advance, nor exceed what the invoice still
        owes. Unlike the auto-FIFO paths (which naturally never cross
        suppliers, since their own candidate queries filter on
        Invoice.supplier_id == advance.supplier_id), this takes raw ids
        directly from a caller — so the same-supplier check has to be
        explicit here instead of falling out of a query filter.
        """
        advance = SupplierGoldAdvance.query.get(advance_id)
        if advance is None:
            raise ValueError(f'gold_advance_not_found:{advance_id}')
        obligation = InvoiceGoldObligation.query.get(obligation_id)
        if obligation is None:
            raise ValueError(f'invoice_gold_obligation_not_found:{obligation_id}')

        obligation_invoice = Invoice.query.get(obligation.invoice_id)
        if obligation_invoice is None or obligation_invoice.supplier_id != advance.supplier_id:
            raise ValueError(
                f'supplier_mismatch:advance_supplier_id={advance.supplier_id},'
                f'obligation_supplier_id={getattr(obligation_invoice, "supplier_id", None)}'
            )

        weight_main_karat = round(float(weight_main_karat), 2)
        if weight_main_karat <= 0:
            raise ValueError('weight_main_karat_must_be_positive')

        advance_available = round(float(advance.weight_remaining_main_karat or 0.0), 2)
        if weight_main_karat > advance_available + WEIGHT_EPSILON:
            raise ValueError(
                f'exceeds_advance_remaining:requested={weight_main_karat},'
                f'available={advance_available}'
            )
        obligation_available = round(float(obligation.weight_remaining_main_karat or 0.0), 2)
        if weight_main_karat > obligation_available + WEIGHT_EPSILON:
            raise ValueError(
                f'exceeds_invoice_obligation_remaining:requested={weight_main_karat},'
                f'available={obligation_available}'
            )

        allocation = GoldAllocation(
            advance_id=advance.id,
            obligation_id=obligation.id,
            weight_applied_main_karat=weight_main_karat,
        )
        db.session.add(allocation)
        advance.weight_remaining_main_karat = round(advance_available - weight_main_karat, 2)
        obligation.weight_remaining_main_karat = round(obligation_available - weight_main_karat, 2)
        db.session.flush()
        return allocation

    # ------------------------------------------------------------------
    # unallocate — DELETE GoldAllocation rows, restore both balances
    # ------------------------------------------------------------------

    def unallocate(self, *, advance_id: int = None, obligation_id: int = None) -> int:
        """Delete every GoldAllocation row matching the given filter(s),
        restoring the weight it had reduced back onto both sides. At least
        one of advance_id / obligation_id must be given.

        Mirrors AllocationService.unallocate()'s delete-on-cancel role.
        The actual CALL SITES (voucher cancellation freeing an Advance;
        a purchase return freeing an Invoice's obligation) are Phase 15C —
        this only provides the mechanism, never decides when to invoke it.

        Returns the count of deleted rows. Caller commits.
        """
        if advance_id is None and obligation_id is None:
            raise ValueError('unallocate_requires_at_least_one_filter')

        query = GoldAllocation.query
        if advance_id is not None:
            query = query.filter_by(advance_id=advance_id)
        if obligation_id is not None:
            query = query.filter_by(obligation_id=obligation_id)

        rows = query.all()
        for row in rows:
            advance = SupplierGoldAdvance.query.get(row.advance_id)
            obligation = InvoiceGoldObligation.query.get(row.obligation_id)
            if advance is not None:
                advance.weight_remaining_main_karat = round(
                    float(advance.weight_remaining_main_karat or 0.0) + row.weight_applied_main_karat, 2
                )
            if obligation is not None:
                obligation.weight_remaining_main_karat = round(
                    float(obligation.weight_remaining_main_karat or 0.0) + row.weight_applied_main_karat, 2
                )
            db.session.delete(row)

        db.session.flush()
        return len(rows)


def create_gold_obligations_for_invoice(invoice: Invoice) -> list[InvoiceGoldObligation]:
    """Normalize this 'شراء' invoice's own recorded gold weight (however it
    was entered) into InvoiceGoldObligation rows — one per real karat — and
    immediately try to auto-allocate each against any open, same-karat
    SupplierGoldAdvance for this supplier.

    PRECEDENCE (Phase 15A-Discovery.2, matches the existing GL-posting
    fallback in posting_routes.py exactly): if this invoice has
    InvoiceKaratLine rows, use those exclusively. Otherwise derive from
    InvoiceItem (weight * quantity, falling back to the linked Item's own
    karat/weight when the InvoiceItem's own fields are blank — a real code
    path, never exercised in production data but handled here defensively).
    Real production evidence: 33/180 real 'شراء' invoices use
    InvoiceKaratLine, 147/180 use InvoiceItem only, and the 4 invoices
    proven to carry BOTH have identical per-karat totals in each — using
    karat_lines and ignoring items in that case double-counts nothing.
    Karat is rounded to the nearest int (default 21 for anything unmapped),
    matching the existing aggregation convention exactly.

    Idempotent: a no-op if this invoice already has any InvoiceGoldObligation
    row (matches sync_gold_advance_after_voucher_approval's own
    existence-check idiom) — a retried call creates nothing new.
    """
    if InvoiceGoldObligation.query.filter_by(invoice_id=invoice.id).first() is not None:
        return []

    by_karat: dict[int, float] = {}

    karat_lines = InvoiceKaratLine.query.filter_by(invoice_id=invoice.id).all()
    if karat_lines:
        for kl in karat_lines:
            karat = int(round(float(kl.karat or 21)))
            weight = float(kl.weight_grams or 0.0)
            if weight <= 0:
                continue
            by_karat[karat] = by_karat.get(karat, 0.0) + weight
    else:
        for item in (invoice.items or []):
            karat_val = item.karat
            weight_val = item.weight
            if karat_val in (None, 0, 0.0) and item.item_id:
                linked = Item.query.get(item.item_id)
                if linked is not None:
                    karat_val = getattr(linked, 'karat', None)
            if weight_val in (None, 0, 0.0) and item.item_id:
                linked = Item.query.get(item.item_id)
                if linked is not None:
                    weight_val = getattr(linked, 'weight', None)
            karat = int(round(float(karat_val or 21)))
            qty = item.quantity if item.quantity and item.quantity > 0 else 1
            weight = float(weight_val or 0.0) * float(qty)
            if weight <= 0:
                continue
            by_karat[karat] = by_karat.get(karat, 0.0) + weight

    svc = GoldAllocationService()
    obligations: list[InvoiceGoldObligation] = []
    for karat, weight in by_karat.items():
        weight = round(weight, 3)
        if weight <= 0:
            continue
        obligation = InvoiceGoldObligation(
            invoice_id=invoice.id,
            karat=karat,
            weight=weight,
            weight_remaining_main_karat=convert_to_main_karat(weight, karat),
        )
        db.session.add(obligation)
        db.session.flush()
        svc.auto_allocate_for_obligation(obligation)
        obligations.append(obligation)

    return obligations


def sync_gold_advance_after_voucher_approval(voucher: Voucher) -> None:
    """Best-effort: create this voucher's SupplierGoldAdvance rows (one per
    karat) and auto-allocate each, right after a voucher with
    reference_type='gold_advance' becomes approved.

    Mirrors sync_invoice_payment_state_after_voucher_approval's own call-site
    set exactly (routes/vouchers.py's approve_voucher; posting_routes.py's
    single approve — both the already-linked-JE branch and the normal one —
    and its batch approve) — same reasoning: every real path that can move a
    voucher into 'approved' must call this the same way. Deliberately does
    NOT also hook create_voucher's voucher_auto_post branch, because the
    existing InvoicePayment sync doesn't either — a separate, pre-existing
    gap, not this phase's to fix.

    The gold given TO the supplier is read from this voucher's own
    VoucherAccountLine rows: amount_type='gold', line_type='debit' — a debit
    on the supplier's memo (Liability) account, matching the real, empirically
    verified direction of a real settlement-to-invoice voucher (Phase 12E:
    voucher #21 -> JE#70, debit_18k=90.8, "طرف السداد"). Credit-side gold
    lines (the safe/inventory leg) are deliberately not read here.

    Idempotent by construction: SupplierGoldAdvance has a UNIQUE constraint
    on (source_voucher_id, karat) (Phase 15A) — this function checks for an
    existing row per karat before creating one, so a retried/duplicate call
    for the same voucher creates nothing new and allocates nothing twice.

    Deliberately swallows its own failure instead of raising, for the same
    reason sync_invoice_payment_state_after_voucher_approval does: real
    accounting (JournalEntry) has already been posted by the time this runs,
    and no caller here is written to roll that back for a downstream
    allocation failure.
    """
    if voucher.reference_type != 'gold_advance' or not voucher.supplier_id:
        return
    try:
        gold_debit_lines = [
            line for line in voucher.account_lines.all()
            if line.amount_type == 'gold' and line.line_type == 'debit' and line.karat
        ]
        by_karat: dict[float, float] = {}
        for line in gold_debit_lines:
            karat = float(line.karat)
            by_karat[karat] = by_karat.get(karat, 0.0) + float(line.amount or 0.0)

        svc = GoldAllocationService()
        for karat, weight in by_karat.items():
            if weight <= 0:
                continue
            existing = SupplierGoldAdvance.query.filter_by(
                source_voucher_id=voucher.id, karat=karat
            ).first()
            if existing is not None:
                continue

            advance = SupplierGoldAdvance(
                supplier_id=voucher.supplier_id,
                source_voucher_id=voucher.id,
                karat=karat,
                weight=round(weight, 3),
                weight_remaining_main_karat=convert_to_main_karat(weight, karat),
            )
            db.session.add(advance)
            db.session.flush()
            svc.auto_allocate_for_advance(advance)
    except Exception as _sync_exc:
        print(f"⚠️ gold advance sync after voucher approve skipped: {_sync_exc}")


def reverse_gold_allocations_for_invoice(invoice_id: int) -> int:
    """Free every GoldAllocation tied to this invoice's own gold obligations,
    restoring the weight back onto whichever SupplierGoldAdvance rows it
    came from. Call this from a purchase-return/cancellation code path
    BEFORE (or as part of) reversing that invoice's own accounting effects
    — mirrors reverse_weight_closing_executions_for_invoice's naming and
    role (accounting/weight_closing.py), for the same reason: an invoice
    that no longer stands must not leave a GoldAllocation pointing at it.

    Best-effort / swallows its own failure, matching every other
    reversal-sync helper in this codebase (sync_invoice_payment_state_after_
    voucher_approval, cancel_voucher's own InvoicePaymentStateService call) —
    the real accounting reversal (the return invoice's own GL lines) is not
    rolled back for a downstream allocation-bookkeeping failure.

    Returns the count of GoldAllocation rows freed (0 if the invoice has no
    gold obligations, or none of them had any allocation yet).
    """
    try:
        obligation_ids = [
            row.id for row in
            InvoiceGoldObligation.query.filter_by(invoice_id=invoice_id).all()
        ]
        if not obligation_ids:
            return 0
        svc = GoldAllocationService()
        total_freed = 0
        for obligation_id in obligation_ids:
            total_freed += svc.unallocate(obligation_id=obligation_id)
        return total_freed
    except Exception as _reversal_exc:
        print(f"⚠️ gold allocation reversal for invoice #{invoice_id} skipped: {_reversal_exc}")
        return 0
