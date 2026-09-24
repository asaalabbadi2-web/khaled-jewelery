"""gold_allocation_service.py — Single Writer for GoldAllocation.

Phase 16C rewrite of the Phase 15 engine, after Phase 16A/16B discovery proved
the original operational model was ~9x disconnected from the GL.

THE CONTRACT (Phase 16C, decided by the business owner):

    GL is the Single Source of Truth.
        |
    (supplier x karat) balance, derived live from the GL -- ALWAYS authoritative
        |
    +-- Supplier-level state: always true, needs no attribution
    |
    +-- Invoice attribution: exists ONLY where it can be evidenced
            +-- an explicit GoldAllocation from a SupplierGoldAdvance
            +-- a direct-linked settlement (Voucher.reference_type='invoice')
            +-- otherwise: UNATTRIBUTED, and named as such

What this means in code, and why each piece is shaped the way it is:

1. NO STORED REMAINING BALANCE. Both weight_remaining_main_karat columns are
   gone (not demoted to a cache). The engagement that produced this module
   began with Invoice.amount_paid drifting from its own source; Phase 16A
   measured the identical failure here -- 31,407g of "remaining" against a
   real GL position of 3,446g -- because the dominant real settlement
   mechanism (115 untagged manual gold-payment vouchers) never wrote to that
   column. Derivation makes the drift structurally impossible instead of
   merely managed. Volumes are tiny (186 obligations), so no cache is needed.

2. TWO DIFFERENT KINDS OF "REMAINING", NEVER CONFLATED.
   - advance_remaining() is EXACT and COMPLETE: an advance can only ever be
     consumed by a GoldAllocation, so weight - sum(allocations) is the whole
     truth.
   - obligation_attributed_remaining() is explicitly *attributed* remaining,
     never a general answer: gross minus only what can be PROVEN to have
     settled this specific invoice. A supplier may well have paid this
     invoice down through a generic voucher; that shows up in the GL and in
     the supplier-level balance, and deliberately NOT here. The name carries
     the caveat so no caller can read it as "what is still owed".

3. NO AUTOMATIC ATTRIBUTION AT ALL. Phase 15's auto-FIFO is deleted, not
   narrowed. Phase 16B proved attribution was genuinely ambiguous at payment
   time (only 11 of 124 real payments had a single candidate invoice; 19 had
   21 or more) and that 0 of 113 real vouchers ever named an invoice, while
   64% used running-account language. "Oldest first" would manufacture
   exactly the attribution the contract forbids. Allocation is therefore
   explicit-only, via allocate().

KARAT RULE (Phase 14, unchanged): SupplierGoldAdvance.karat/weight and
InvoiceGoldObligation.karat/weight are each the REAL karat an event actually
happened in -- never converted. Only a BALANCE or a comparison across karats
is main-karat-equivalent, because subtracting across differing karats is only
possible in a common unit. Phase 16A found 8 of 34 real direct-linked
settlements settle a karat the invoice never contained, so netting a
settlement against an obligation REQUIRES that conversion -- same-karat
matching would silently miss ~24% of them.

SCOPE: this service does matching/bookkeeping only. It never creates
Vouchers, VoucherAccountLines or JournalEntries, and it never posts a
karat-mismatch fee.
"""
from __future__ import annotations

from models import (
    db,
    GoldAllocation,
    GoldAttributionBoundary,
    Invoice,
    InvoiceGoldObligation,
    InvoiceKaratLine,
    Item,
    JournalEntry,
    JournalEntryLine,
    SupplierGoldAdvance,
    Voucher,
    VoucherInvoiceGoldAttribution,
)
from pricing.karat_service import convert_to_main_karat

WEIGHT_EPSILON = 0.005

PURCHASE_INVOICE_TYPE = 'شراء'


# ======================================================================
# Eligibility -- the single gate, shared by the live path and the backfill
# ======================================================================

def is_gold_obligation_eligible(invoice) -> bool:
    """Does this invoice create a real supplier gold obligation?

    Phase 16A proved office-reservation settlement invoices do not, at the
    level of code rather than correlation: Invoice.office_id is set in exactly
    one place (routes/office_reservations.py, the reservation-settlement
    purchase invoice, always with wage_subtotal=0.0), and that flow's own
    JournalEntry posts CASH ONLY -- create_dual_journal_entry is called with
    no weight parameter at all. Such an invoice therefore has zero gold
    liability in the GL by construction, and any obligation row for it would
    be a phantom (29 such rows, 5,521.81g, existed in the local copy).

    Deliberately one named predicate rather than an inline filter, so the
    eligibility contract has exactly one definition that both the live path
    and the migration backfill read.
    """
    if invoice is None:
        return False
    if getattr(invoice, 'invoice_type', None) != PURCHASE_INVOICE_TYPE:
        return False
    if getattr(invoice, 'office_id', None) is not None:
        return False
    return True


# ======================================================================
# Derived quantities -- nothing below is ever stored
# ======================================================================

def advance_remaining(advance: SupplierGoldAdvance) -> float:
    """Unallocated weight of this advance, main-karat-equivalent.

    EXACT and COMPLETE: a GoldAllocation is the only way an advance can be
    consumed, so this is the whole truth about it, not an approximation.
    """
    if advance is None:
        return 0.0
    gross = convert_to_main_karat(float(advance.weight or 0.0), advance.karat)
    applied = db.session.query(
        db.func.coalesce(db.func.sum(GoldAllocation.weight_applied_main_karat), 0.0)
    ).filter(GoldAllocation.advance_id == advance.id).scalar() or 0.0
    return round(float(gross) - float(applied), 2)


def obligation_attributed_settlement(obligation: InvoiceGoldObligation) -> float:
    """Weight settled against this obligation that can be PROVEN to belong to
    it, main-karat-equivalent. Two evidenced sources, and no others:

      1. explicit GoldAllocation rows from a SupplierGoldAdvance;
      2. direct-linked settlement -- an approved Voucher carrying
         reference_type='invoice' and reference_id = this invoice, whose gold
         debit reduces this supplier's liability (Phase 12E mechanism A, 34
         real vouchers, linkage 100% reliable).

    Mechanism A is DERIVED here, never stored in a table of its own: the
    evidence already exists on the voucher and in the GL, and the contract
    makes this module an interpretation layer over the GL, not a second
    ledger.

    The direct-linked share is attributed at the INVOICE level (that is what
    reference_id proves) and split across that invoice's karats in proportion
    to their gross weight, because Phase 16A found 8 of 34 such vouchers
    settle a karat the invoice never contained -- so a settlement cannot be
    assumed to belong to a matching-karat obligation row.
    """
    if obligation is None:
        return 0.0

    allocated = db.session.query(
        db.func.coalesce(db.func.sum(GoldAllocation.weight_applied_main_karat), 0.0)
    ).filter(GoldAllocation.obligation_id == obligation.id).scalar() or 0.0

    direct = _direct_linked_settlement_share_for_obligation(obligation)
    return round(float(allocated) + float(direct), 2)


def obligation_attributed_remaining(obligation: InvoiceGoldObligation) -> float:
    """Gross obligation minus evidenced settlement, main-karat-equivalent.

    NOT "what is still owed on this invoice". A generic supplier gold payment
    reduces the real liability without naming any invoice, and by contract
    that reduction is visible at (supplier x karat) level only -- never
    imputed to an invoice here. Read this figure together with the
    unattributed residual from reconcile_supplier(); alone it is an upper
    bound, not a fact.
    """
    if obligation is None:
        return 0.0
    gross = convert_to_main_karat(float(obligation.weight or 0.0), obligation.karat)
    remaining = float(gross) - obligation_attributed_settlement(obligation)
    return round(max(remaining, 0.0), 2)


def _direct_linked_settlement_share_for_obligation(obligation: InvoiceGoldObligation) -> float:
    """This obligation's proportional share of its invoice's direct-linked
    settlement, main-karat-equivalent. See obligation_attributed_settlement
    for why the split is proportional rather than karat-matched.
    """
    invoice_total = direct_linked_settlement_for_invoice(obligation.invoice_id)
    if invoice_total <= 0:
        return 0.0

    siblings = InvoiceGoldObligation.query.filter_by(invoice_id=obligation.invoice_id).all()
    gross_by_id = {
        row.id: float(convert_to_main_karat(float(row.weight or 0.0), row.karat))
        for row in siblings
    }
    total_gross = sum(gross_by_id.values())
    if total_gross <= 0:
        return 0.0

    own_gross = gross_by_id.get(obligation.id, 0.0)
    share = invoice_total * (own_gross / total_gross)
    # Never credit an obligation with more than its own gross.
    return round(min(share, own_gross), 2)


def historical_attribution_boundary() -> int:
    """The highest voucher id whose invoice gold attribution may be DERIVED.

    Captured once by migration 20260924_voucher_invoice_gold_attr and never
    recomputed. Above it, only VoucherInvoiceGoldAttribution counts, so a
    voucher can never have two competing answers. Returns 0 if the row is
    missing, which fails CLOSED: nothing is derived, and only recorded
    attribution is honoured.
    """
    row = GoldAttributionBoundary.query.order_by(GoldAttributionBoundary.id.asc()).first()
    return int(getattr(row, 'max_historical_voucher_id', 0) or 0)


def recorded_attribution_for_invoice(invoice_id: int) -> float:
    """Gold attributed to this invoice by an explicit human decision,
    main-karat-equivalent. The forward-facing path: rows exist because someone
    chose this invoice, never because anything inferred it."""
    if not invoice_id:
        return 0.0
    total = db.session.query(
        db.func.coalesce(db.func.sum(VoucherInvoiceGoldAttribution.weight_main_karat), 0.0)
    ).filter(VoucherInvoiceGoldAttribution.invoice_id == invoice_id).scalar()
    return round(float(total or 0.0), 2)


def direct_linked_settlement_for_invoice(invoice_id: int) -> float:
    """Total gold settled against this invoice by evidence, main-karat-equivalent.

    Two sources, and exactly one of them can ever speak for a given voucher:

      1. RECORDED — VoucherInvoiceGoldAttribution rows (the only path for new
         vouchers).
      2. DERIVED — Phase 12E "mechanism A": a voucher carrying
         reference_type='invoice' whose GL lines debit this supplier's gold.
         Restricted to vouchers at or below historical_attribution_boundary(),
         and further restricted to vouchers that have NO recorded rows.

    That second restriction is what makes the two sources one answer: a voucher
    below the boundary that has since been given explicit rows is read from its
    rows only, never counted twice.

    The derived side reads the GL rather than the voucher's own lines, because
    the GL is the contract's Single Source and a voucher that was never posted
    must not count as settlement. A supplier-tagged gold DEBIT reduces the
    supplier's gold liability -- verified on real data (Phase 12E: voucher #21
    -> JE#70, debit_18k=90.8).
    """
    if not invoice_id:
        return 0.0

    recorded = recorded_attribution_for_invoice(invoice_id)

    boundary = historical_attribution_boundary()
    if boundary <= 0:
        return recorded

    vouchers_with_rows = db.session.query(
        VoucherInvoiceGoldAttribution.voucher_id
    ).distinct().subquery()

    voucher_ids = [
        row.id for row in
        Voucher.query.filter(
            Voucher.reference_type == 'invoice',
            Voucher.reference_id == invoice_id,
            Voucher.status == 'approved',
            Voucher.id <= boundary,
            ~Voucher.id.in_(db.session.query(vouchers_with_rows.c.voucher_id)),
        ).all()
    ]
    if not voucher_ids:
        return recorded

    rows = (
        db.session.query(
            JournalEntryLine.debit_18k,
            JournalEntryLine.debit_21k,
            JournalEntryLine.debit_22k,
            JournalEntryLine.debit_24k,
        )
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .filter(
            JournalEntry.reference_type == 'voucher',
            JournalEntry.reference_id.in_(voucher_ids),
            JournalEntryLine.supplier_id.isnot(None),
        )
        .all()
    )

    derived = 0.0
    for d18, d21, d22, d24 in rows:
        for karat, weight in ((18, d18), (21, d21), (22, d22), (24, d24)):
            weight = float(weight or 0.0)
            if weight > 0:
                derived += float(convert_to_main_karat(weight, karat))
    return round(recorded + derived, 2)


# ======================================================================
# Reconciliation -- the named residual that keeps the model honest
# ======================================================================

def reconcile_supplier(supplier) -> dict:
    """Reconcile one supplier's gold position, in main-karat-equivalent.

    Returns the four quantities of the contract's identity:

        gross_obligation - attributed_settlement - unattributed_settlement
            == gl_position

    where unattributed_settlement is the NAMED residual: real settlement that
    the GL proves happened but which no evidence attributes to any invoice
    (Phase 16B: 115 real vouchers, 14,581g, 0 of which ever named an
    invoice). Naming it is the whole point -- without it, anyone summing
    obligations re-derives the 31,407g figure Phase 16A proved wrong, and the
    temptation is to "fix" the gap by inventing an allocation.

    gl_position is the authoritative liability, taken from the existing
    canonical source (compute_live_supplier_balances, itself declared as the
    Single Source by supplier_settlement_adjustment_service) and sign-flipped:
    that function reports debit - credit, so an outstanding gold liability
    reads negative there and positive here.
    """
    from services.party_live_balances import compute_live_supplier_balances

    balances = compute_live_supplier_balances([supplier]).get(int(supplier.id)) or {}
    gl_position = 0.0
    for karat in (18, 21, 22, 24):
        raw = float(balances.get(f'{karat}k', 0.0) or 0.0)
        if raw:
            gl_position += float(convert_to_main_karat(-raw, karat))

    obligations = (
        InvoiceGoldObligation.query
        .join(Invoice, Invoice.id == InvoiceGoldObligation.invoice_id)
        .filter(Invoice.supplier_id == supplier.id)
        .all()
    )

    gross = 0.0
    attributed = 0.0
    for obligation in obligations:
        gross += float(convert_to_main_karat(float(obligation.weight or 0.0), obligation.karat))
        attributed += obligation_attributed_settlement(obligation)

    gross = round(gross, 2)
    attributed = round(attributed, 2)
    gl_position = round(gl_position, 2)

    return {
        'supplier_id': int(supplier.id),
        'unit': 'main_karat_equivalent',
        'gross_obligation': gross,
        'attributed_settlement': attributed,
        'unattributed_settlement': round(gross - attributed - gl_position, 2),
        'gl_position': gl_position,
        'unallocated_advances': round(sum(
            advance_remaining(advance) for advance in
            SupplierGoldAdvance.query.filter_by(supplier_id=supplier.id).all()
        ), 2),
    }


# ======================================================================
# The single writer
# ======================================================================

class GoldAllocationService:
    """Usage:

        svc = GoldAllocationService()

        # A human explicitly attributes part of an advance to one obligation:
        svc.allocate(advance_id=..., obligation_id=..., weight_main_karat=...)

        # Reversal (voucher cancel / purchase return):
        svc.unallocate(advance_id=...)   # or obligation_id=..., or both

    There is deliberately no auto_allocate / build_plan API: Phase 16C's
    contract forbids attribution that no human declared, so no code path
    creates a GoldAllocation on its own.
    """

    def allocate(
        self,
        *,
        advance_id: int,
        obligation_id: int,
        weight_main_karat: float,
    ) -> GoldAllocation:
        """Attribute exactly this much of exactly this advance to exactly this
        invoice obligation, because a human said so.

        Bounds-checked against both sides' DERIVED remaining: an explicit
        decision may choose WHICH obligation is settled, never fabricate
        weight the advance does not have, nor credit an obligation beyond
        what it can still evidence. Cross-karat allocation is permitted --
        both sides are compared in main-karat-equivalent, matching the real
        karat_diff_* mechanism where a human decides a cross-karat
        settlement -- but crossing SUPPLIERS never is.
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

        available = advance_remaining(advance)
        if weight_main_karat > available + WEIGHT_EPSILON:
            raise ValueError(
                f'exceeds_advance_remaining:requested={weight_main_karat},'
                f'available={available}'
            )
        obligation_available = obligation_attributed_remaining(obligation)
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
        db.session.flush()
        _resync_invoice_status(obligation.invoice_id)
        return allocation

    def unallocate(self, *, advance_id: int = None, obligation_id: int = None) -> int:
        """Delete every GoldAllocation row matching the given filter(s). At
        least one of advance_id / obligation_id must be given.

        No balance restoration step exists any more: both sides' remaining is
        derived from these very rows, so deleting them IS the restoration.

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
        touched_invoice_ids = set()
        for row in rows:
            obligation = InvoiceGoldObligation.query.get(row.obligation_id)
            if obligation is not None:
                touched_invoice_ids.add(obligation.invoice_id)
            db.session.delete(row)
        db.session.flush()
        for invoice_id in touched_invoice_ids:
            _resync_invoice_status(invoice_id)
        return len(rows)


def create_gold_obligations_for_invoice(invoice: Invoice) -> list[InvoiceGoldObligation]:
    """Record this invoice's ORIGINAL gross gold obligation -- one immutable
    row per real karat -- and attribute nothing.

    Phase 16C: no auto-allocation happens here. A supplier may hold an older
    unallocated advance; that does NOT mean it paid this invoice, and the
    contract forbids inferring that it did.

    Eligibility is checked through is_gold_obligation_eligible() rather than
    an inline invoice_type test, so office-reservation settlement invoices
    (which post no gold to the GL at all) never produce a phantom row.

    PRECEDENCE (Phase 15A-Discovery.2, matches the existing GL-posting
    fallback in posting_routes.py exactly): if this invoice has
    InvoiceKaratLine rows, use those exclusively. Otherwise derive from
    InvoiceItem (weight * quantity, falling back to the linked Item's own
    karat/weight when the InvoiceItem's own fields are blank). Real evidence:
    33/180 real 'شراء' invoices use InvoiceKaratLine, 147/180 use InvoiceItem
    only, and the 4 carrying both have identical per-karat totals in each.
    Karat is rounded to the nearest int (default 21 for anything unmapped).

    Idempotent: a no-op if this invoice already has any obligation row.
    """
    if not is_gold_obligation_eligible(invoice):
        return []
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

    obligations: list[InvoiceGoldObligation] = []
    for karat, weight in by_karat.items():
        weight = round(weight, 3)
        if weight <= 0:
            continue
        obligation = InvoiceGoldObligation(
            invoice_id=invoice.id,
            karat=karat,
            weight=weight,
        )
        db.session.add(obligation)
        db.session.flush()
        obligations.append(obligation)

    if obligations:
        _resync_invoice_status(invoice.id)
    return obligations


def sync_gold_advance_after_voucher_approval(voucher: Voucher) -> None:
    """Best-effort: record this voucher's SupplierGoldAdvance rows (one per
    karat) right after a voucher with reference_type='gold_advance' becomes
    approved. The advance is created UNALLOCATED -- Phase 16C removed the
    auto-allocation that used to follow.

    Mirrors sync_invoice_payment_state_after_voucher_approval's own call-site
    set exactly (routes/vouchers.py's approve_voucher; posting_routes.py's
    single approve -- both the already-linked-JE branch and the normal one --
    and its batch approve): every real path that can move a voucher into
    'approved' must call this the same way.

    The gold given TO the supplier is read from this voucher's own
    VoucherAccountLine rows: amount_type='gold', line_type='debit' -- a debit
    on the supplier's memo (Liability) account, matching the empirically
    verified direction of a real settlement voucher (Phase 12E: voucher #21
    -> JE#70, debit_18k=90.8). Credit-side gold lines (the safe/inventory
    leg) are deliberately not read here.

    Idempotent by construction: SupplierGoldAdvance has a UNIQUE constraint
    on (source_voucher_id, karat) -- this checks for an existing row per
    karat first, so a retried call creates nothing new.

    Deliberately swallows its own failure instead of raising, for the same
    reason sync_invoice_payment_state_after_voucher_approval does: real
    accounting (JournalEntry) has already been posted by the time this runs,
    and no caller here is written to roll that back for a downstream
    bookkeeping failure.
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

        for karat, weight in by_karat.items():
            if weight <= 0:
                continue
            existing = SupplierGoldAdvance.query.filter_by(
                source_voucher_id=voucher.id, karat=karat
            ).first()
            if existing is not None:
                continue

            db.session.add(SupplierGoldAdvance(
                supplier_id=voucher.supplier_id,
                source_voucher_id=voucher.id,
                karat=karat,
                weight=round(weight, 3),
            ))
            db.session.flush()
    except Exception as _sync_exc:
        print(f"⚠️ gold advance sync after voucher approve skipped: {_sync_exc}")


def _resync_invoice_status(invoice_id: int) -> None:
    """Recompute the invoice's payment status after a gold event.

    Invoice.status is a stored column read by lists, filters and reports, and it
    now depends on the gold side too — so every gold event that can change what
    is attributed MUST land here, or the column drifts. That is the fourth cache
    in this codebase, so the trigger set is deliberately small and enumerable:
    attribution written or removed, an allocation applied or freed, obligations
    created. A ratchet test asserts each of those paths calls this.

    Imported lazily to avoid an import cycle, and best-effort on purpose: the
    real accounting is already committed by the time a gold event lands, and a
    status refresh failing must not roll it back. A drifted status is
    recoverable by recomputing; a lost GL entry is not.
    """
    if not invoice_id:
        return
    try:
        from services.invoice_payment_state_service import InvoicePaymentStateService
        invoice = Invoice.query.get(invoice_id)
        if invoice is not None:
            InvoicePaymentStateService().recompute(invoice)
    except Exception as exc:
        print(f"⚠️ invoice #{invoice_id} status resync after a gold event skipped: {exc}")


def invoice_open_gold_obligation(invoice_id: int) -> float:
    """What this invoice can still have evidenced against it, main-karat-equivalent.

    THE shared ceiling. One obligation has three consumers — advance
    allocations, recorded attribution, and the bounded historical derivation —
    and they draw from one budget. Checking each against its own copy of the
    ceiling is how a 60g advance plus a 60g attribution would "settle" a 100g
    obligation, so every bound check goes through here.
    """
    obligations = InvoiceGoldObligation.query.filter_by(invoice_id=invoice_id).all()
    return round(sum(obligation_attributed_remaining(o) for o in obligations), 2)


def attribute_gold_to_invoice(
    *,
    voucher,
    invoice_id: int,
    karat: float,
    weight: float,
    created_by: str = None,
) -> VoucherInvoiceGoldAttribution:
    """Record that this much of *voucher*'s gold settles this invoice.

    Never called on its own initiative: either a person chose this invoice, or
    the invoice-creation flow is recording its own immediate settlement. There
    is no FIFO and no inference anywhere in this module.

    *karat* and *weight* are what was actually handed over and are stored as
    given; the main-karat-equivalent is derived from them for balancing only.

    Raises on: an unapproved voucher, a supplier mismatch, a non-positive
    weight, more weight than the voucher itself carries, and more than the
    invoice's remaining obligation can evidence. Caller commits.
    """
    if voucher is None:
        raise ValueError('voucher_required')
    if getattr(voucher, 'status', None) != 'approved':
        raise ValueError(f'voucher_not_approved:{getattr(voucher, "status", None)}')

    invoice = Invoice.query.get(invoice_id)
    if invoice is None:
        raise ValueError(f'invoice_not_found:{invoice_id}')
    if voucher.supplier_id and invoice.supplier_id != voucher.supplier_id:
        raise ValueError(
            f'supplier_mismatch:voucher_supplier_id={voucher.supplier_id},'
            f'invoice_supplier_id={invoice.supplier_id}'
        )

    weight = round(float(weight or 0.0), 3)
    if weight <= 0:
        raise ValueError('weight_must_be_positive')

    weight_main_karat = round(float(convert_to_main_karat(weight, karat)), 2)

    already_attributed = db.session.query(
        db.func.coalesce(db.func.sum(VoucherInvoiceGoldAttribution.weight_main_karat), 0.0)
    ).filter(VoucherInvoiceGoldAttribution.voucher_id == voucher.id).scalar() or 0.0
    voucher_capacity = _voucher_gold_capacity_main_karat(voucher)
    if round(float(already_attributed) + weight_main_karat, 2) > voucher_capacity + WEIGHT_EPSILON:
        raise ValueError(
            f'exceeds_voucher_gold:requested={weight_main_karat},'
            f'already={round(float(already_attributed), 2)},capacity={voucher_capacity}'
        )

    open_obligation = invoice_open_gold_obligation(invoice_id)
    if weight_main_karat > open_obligation + WEIGHT_EPSILON:
        raise ValueError(
            f'exceeds_invoice_obligation_remaining:requested={weight_main_karat},'
            f'available={open_obligation}'
        )

    row = VoucherInvoiceGoldAttribution(
        voucher_id=voucher.id,
        invoice_id=invoice_id,
        karat=float(karat),
        weight=weight,
        weight_main_karat=weight_main_karat,
        created_by=created_by,
    )
    db.session.add(row)
    db.session.flush()
    _resync_invoice_status(invoice_id)
    return row


def _voucher_gold_capacity_main_karat(voucher) -> float:
    """How much gold this voucher actually moved, main-karat-equivalent, read
    from its own gold debit lines — the same lines the Advance path reads."""
    total = 0.0
    try:
        for line in voucher.account_lines.all():
            if line.amount_type == 'gold' and line.line_type == 'debit' and line.karat:
                total += float(convert_to_main_karat(float(line.amount or 0.0), float(line.karat)))
    except Exception:
        return 0.0
    return round(total, 2)


def sync_gold_attribution_after_voucher_approval(voucher) -> int:
    """Record this voucher's invoice gold attribution, at approval.

    Approval is the only moment this may happen, and it happens inside the
    approving transaction: an attribution must never exist without an approved
    voucher behind it, and a voucher must never post its GL and leave its
    attribution unwritten. **This deliberately does NOT swallow its failures**,
    unlike sync_gold_advance_after_voucher_approval — if the attribution cannot
    be written the whole approval must fail, because a posted settlement with no
    attribution is precisely the state that made 81% of the historical data
    unattributable.

    Reads the voucher's declared intent, nothing more: `reference_type='invoice'`
    plus `reference_id` says which invoice, and the gold DEBIT lines say how much
    of which karat. One row per karat, keeping the real karat. No FIFO, no
    inference, no guessing which invoice was meant.

    Covers Mechanism A (the invoice-creation flow's own immediate settlement,
    which builds exactly such a voucher) and the employee's explicit
    "this payment is for invoice X" choice — one path for both.

    Idempotent: a retried approval finds rows already present and writes none.
    Returns the number of rows created.
    """
    if getattr(voucher, 'reference_type', None) != 'invoice':
        return 0
    if not getattr(voucher, 'reference_id', None) or not getattr(voucher, 'supplier_id', None):
        return 0
    if getattr(voucher, 'status', None) != 'approved':
        return 0

    if VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).first() is not None:
        return 0

    by_karat: dict[float, float] = {}
    for line in voucher.account_lines.all():
        if line.amount_type == 'gold' and line.line_type == 'debit' and line.karat:
            karat = float(line.karat)
            by_karat[karat] = by_karat.get(karat, 0.0) + float(line.amount or 0.0)
    if not by_karat:
        return 0

    created = 0
    for karat, weight in by_karat.items():
        if weight <= 0:
            continue
        attribute_gold_to_invoice(
            voucher=voucher,
            invoice_id=int(voucher.reference_id),
            karat=karat,
            weight=weight,
            created_by=getattr(voucher, 'created_by', None),
        )
        created += 1
    return created


def remove_attributions_for_voucher(voucher_id: int) -> int:
    """Delete every attribution this voucher recorded. Called when the voucher
    is cancelled — an attribution must never outlive the payment that proves
    it (the AV-2026-00223 lesson). Returns the count removed. Caller commits.
    """
    rows = VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher_id).all()
    invoice_ids = {row.invoice_id for row in rows}
    for row in rows:
        db.session.delete(row)
    db.session.flush()
    for invoice_id in invoice_ids:
        _resync_invoice_status(invoice_id)
    return len(rows)


def reverse_gold_allocations_for_invoice(invoice_id: int) -> int:
    """Free every GoldAllocation tied to this invoice's own gold obligations.
    Call this from a purchase-return/cancellation code path -- mirrors
    reverse_weight_closing_executions_for_invoice's naming and role
    (accounting/weight_closing.py), for the same reason: an invoice that no
    longer stands must not leave a GoldAllocation pointing at it.

    The obligation rows themselves are left in place: they record what the
    invoice originally obliged, which remains historically true.

    Best-effort / swallows its own failure, matching every other reversal-sync
    helper in this codebase -- the real accounting reversal (the return
    invoice's own GL lines) is not rolled back for a downstream
    allocation-bookkeeping failure.

    Returns the count of GoldAllocation rows freed.
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
