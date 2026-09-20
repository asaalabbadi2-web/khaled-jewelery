#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Fix Group A's stale Invoice.amount_paid cache (Phase 10B).

Phase 10 (historical 47-mismatch discovery) found 13 invoices where a real,
active InvoicePayment already exists and its sum exactly equals
invoice.total, but the stored amount_paid was left at 0.0 -- almost
certainly because whatever wrote these rows (all sale invoices, all
"admin", all dated 2026-03-05..2026-03-07 -- the earliest live sales
activity in the dataset, right after the Jan-1 opening-balance import)
never called any amount_paid/status recompute at all. Stored status was
already 'paid' in every one of the 13 and needs no change.

This is the SAFEST of Phase 10's six mismatch groups to correct: nothing
here fabricates a new historical event. It only re-runs the one canonical
formula (InvoicePaymentStateService.recompute()) against evidence
(InvoicePayment rows) that already exists and is already trusted for every
other invoice in the system today.

Scope, on purpose:
- Exactly the 13 ids in TARGET_INVOICE_IDS. Not a general "recompute
  anything that looks stale" tool -- Phase 10's other five groups (C, F, H,
  B, J) have different root causes and different risk profiles, and are
  explicitly out of scope here. See the Phase 10 / 10B reports.
- No new formula. check_invoice_safety() and repair_group_a() both compute
  the expected state by calling InvoicePaymentStateService().recompute()
  directly -- never by re-deriving SUM(InvoicePayment.amount) or a status
  threshold locally.
- amount-only: an invoice whose canonical status would also change is
  rejected, not corrected. Group A's own definition is "status was already
  right, only amount_paid wasn't" -- a case where status would change too
  is a different shape and does not belong in this batch.

Safety
- Default is DRY RUN (no commit). Use --apply to write.
- Every target id is independently validated against current live evidence
  right before it is (or is not) corrected -- eligibility is never assumed
  from a prior discovery pass.
- Single transaction: all eligible corrections in one call are staged, then
  committed together once at the end. Any unhandled exception mid-batch
  rolls back everything staged so far; nothing is left half-applied.
- Idempotent: recompute() is a no-op once amount_paid already matches, so a
  second run reports corrected=0 for ids already fixed.

Usage
  python3 devtools/fix_group_a_amount_paid_cache.py
  python3 devtools/fix_group_a_amount_paid_cache.py --apply

DB targeting: point at the correct DB via DATABASE_URL if needed.
"""
from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass, field

os.environ.setdefault("BYPASS_AUTH_FOR_DEVELOPMENT", "1")

BACKEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from models import Invoice, InvoicePayment, Voucher, db  # noqa: E402
from services.invoice_payment_state_service import InvoicePaymentStateService  # noqa: E402

CASH_EPSILON = 0.01

TARGET_INVOICE_IDS: tuple[int, ...] = (
    406, 407, 427, 428, 429, 430, 431, 432, 434, 435, 437, 438, 439,
)


@dataclass(frozen=True)
class SafetyCheckResult:
    invoice_id: int
    eligible: bool
    reason: str
    stored_amount_paid: float
    stored_status: str
    expected_amount_paid: float
    expected_status: str
    active_payment_count: int


@dataclass
class RepairReport:
    corrected: int = 0
    rejected: int = 0
    results: list[SafetyCheckResult] = field(default_factory=list)


def _active_payment_count(invoice_id: int) -> int:
    """Count InvoicePayment rows this invoice's canonical sum treats as
    active -- same rule as InvoicePaymentStateService._sum_invoice_payments:
    a NULL source_voucher_id is active; a non-NULL one is active unless its
    voucher is cancelled. Used only to gate eligibility (condition A/B); the
    amount itself always comes from the real service call, never from this
    count."""
    rows = InvoicePayment.query.filter_by(invoice_id=invoice_id).all()
    count = 0
    for p in rows:
        if p.source_voucher_id is None:
            count += 1
            continue
        v = Voucher.query.get(p.source_voucher_id)
        if v is None or v.status != 'cancelled':
            count += 1
    return count


def check_invoice_safety(invoice: Invoice) -> SafetyCheckResult:
    """Dry-run safety check for one invoice. Never persists a change --
    calls the real InvoicePaymentStateService.recompute() to get the
    canonical expected state, then always rolls back before returning.

    Eligible only if ALL of:
      A/B. at least one InvoicePayment is active per the canonical
           cancellation rule (source_voucher_id NULL or non-cancelled).
      C/D. the canonical recompute() result is 'paid' and its amount
           matches invoice.total (within CASH_EPSILON) -- this is computed
           by the real service, so barter_total and the cancellation rule
           are automatically accounted for; nothing here re-derives them.
      E.   invoice.total is a real positive amount (not the zero-total
           auto-paid edge case in _status_for, which needs no payment
           evidence at all and is a different shape than Group A).
      F.   the canonical status does not change (stored status was already
           right) -- Group A is an amount-only correction by definition;
           anything that would also change status is a different shape and
           is rejected here, not silently corrected.
    """
    invoice_id = int(invoice.id)
    stored_amount_paid = round(float(invoice.amount_paid or 0.0), 2)
    stored_status = invoice.status
    total = round(float(invoice.total or 0.0), 2)

    active_count = _active_payment_count(invoice_id)

    result = InvoicePaymentStateService().recompute(invoice)
    expected_amount_paid = result.amount_paid
    expected_status = result.status
    db.session.rollback()

    if total <= CASH_EPSILON:
        return SafetyCheckResult(
            invoice_id, False, "zero_or_negative_total_not_group_a_shape",
            stored_amount_paid, stored_status, expected_amount_paid, expected_status, active_count,
        )
    if active_count < 1:
        return SafetyCheckResult(
            invoice_id, False, "no_active_invoice_payment_evidence",
            stored_amount_paid, stored_status, expected_amount_paid, expected_status, active_count,
        )
    if expected_status != 'paid' or abs(expected_amount_paid - total) > CASH_EPSILON:
        return SafetyCheckResult(
            invoice_id, False, "canonical_result_is_not_fully_paid",
            stored_amount_paid, stored_status, expected_amount_paid, expected_status, active_count,
        )
    if expected_status != stored_status:
        return SafetyCheckResult(
            invoice_id, False, "status_would_also_change_not_amount_only",
            stored_amount_paid, stored_status, expected_amount_paid, expected_status, active_count,
        )

    return SafetyCheckResult(
        invoice_id, True, "canonical_invoice_payment_evidence_amount_only",
        stored_amount_paid, stored_status, expected_amount_paid, expected_status, active_count,
    )


def repair_group_a(*, apply: bool, target_ids=TARGET_INVOICE_IDS) -> RepairReport:
    """Re-validate and, if apply=True, correct every id in target_ids.

    Rejects are isolated per-invoice (one ineligible id never blocks its
    eligible siblings in the same call) but every eligible correction in
    the batch is staged together and committed exactly once at the end --
    an unhandled exception during that staging rolls back the whole batch,
    never leaving one invoice corrected and another half-written.
    """
    report = RepairReport()
    to_apply: list[tuple[Invoice, SafetyCheckResult]] = []

    for inv_id in target_ids:
        invoice = Invoice.query.get(int(inv_id))
        if invoice is None:
            report.results.append(SafetyCheckResult(
                int(inv_id), False, "invoice_not_found", 0.0, "", 0.0, "", 0,
            ))
            report.rejected += 1
            continue

        result = check_invoice_safety(invoice)
        report.results.append(result)
        if not result.eligible:
            report.rejected += 1
            continue
        to_apply.append((invoice, result))

    if not apply:
        report.corrected = 0
        return report

    actually_changed = 0
    try:
        for invoice, result in to_apply:
            live = InvoicePaymentStateService().recompute(invoice)
            if live.status != 'paid' or abs(live.amount_paid - result.expected_amount_paid) > CASH_EPSILON:
                raise RuntimeError(
                    f"invoice {invoice.id}: live recompute at write time "
                    f"({live.amount_paid}, {live.status}) no longer matches "
                    f"the dry-run check ({result.expected_amount_paid}, {result.expected_status}) "
                    "-- aborting whole batch rather than applying stale evidence"
                )
            # Idempotency: an invoice already at its canonical value is still
            # eligible (its evidence is still valid Group A evidence) but is
            # not a fresh correction -- recompute()'s own changed flag is the
            # single source of truth for "did this row's stored value move",
            # not "was this invoice in the eligible set".
            if live.changed:
                actually_changed += 1
        db.session.commit()
    except Exception:
        db.session.rollback()
        raise

    report.corrected = actually_changed
    return report


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Phase 10B -- fix Group A's stale amount_paid cache (13 known ids)")
    p.add_argument("--apply", action="store_true")
    args = p.parse_args(argv)

    from app import app

    with app.app_context():
        report = repair_group_a(apply=bool(args.apply))
        for r in report.results:
            tag = "ELIGIBLE" if r.eligible else "BLOCKED "
            print(
                f"{tag} invoice={r.invoice_id} stored=({r.stored_amount_paid}, {r.stored_status}) "
                f"expected=({r.expected_amount_paid}, {r.expected_status}) reason={r.reason}"
            )
        print()
        print(f"eligible_for_correction = {sum(1 for r in report.results if r.eligible)}")
        print(f"rejected = {sum(1 for r in report.results if not r.eligible)}")
        if args.apply:
            print(f"corrected = {report.corrected}")
            print("DONE")
        else:
            print("DRY RUN -- no changes committed. Re-run with --apply to write.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
