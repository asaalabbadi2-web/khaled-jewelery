"""allocation_service.py — Single Writer for SettlementLine.

ARCHITECTURAL INVARIANT:
    SettlementLine is append/delete-only in production code.
    No in-place UPDATE (line.amount_settled = ...) is permitted outside of
    named, targeted repair scripts (e.g. fix_av045_ip1003_settlement_line.py).

    All CREATE operations must go through AllocationService.allocate().
    All DELETE operations must go through AllocationService.unallocate().

    This mirrors the Single-Writer pattern used by AccountPairService and
    SettlementStateService: one service owns the writes; everyone else reads.

RESPONSIBILITIES (this module):
    - Linking InvoicePayments to settlement Vouchers via SettlementLine.
    - FIFO allocation with partial-settlement support.
    - Prorating commission/VAT across IPs by amount ratio.

NOT RESPONSIBLE FOR:
    - Creating Vouchers, VoucherAccountLines, or JournalEntries.
    - Validating clearing balances or due amounts.
    - Committing the database session (callers commit).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import func

from models import db, SettlementLine, InvoicePayment, Voucher


# ---------------------------------------------------------------------------
# Data transfer objects (pure data — no DB writes)
# ---------------------------------------------------------------------------

@dataclass
class AllocationLine:
    """One line of an allocation plan: how much of one IP this voucher covers."""
    invoice_payment_id: int
    amount_to_allocate: float
    commission: float
    commission_vat: float


@dataclass
class AllocationPlan:
    """Result of build_allocation_plan() — pure data, no DB writes.

    Callers can inspect this before deciding whether to apply it via allocate().
    """
    voucher_id: int
    gross_amount: float
    lines: list[AllocationLine] = field(default_factory=list)
    unallocated_remainder: float = 0.0

    @property
    def is_fully_covered(self) -> bool:
        """True when gross_amount is fully distributed across lines."""
        return self.unallocated_remainder <= 0.005

    @property
    def total_allocated(self) -> float:
        return round(sum(ln.amount_to_allocate for ln in self.lines), 2)


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

class AllocationService:
    """Single writer for SettlementLine.

    Usage pattern:
        svc = AllocationService()

        # Preview (no writes):
        plan = svc.build_allocation_plan(voucher=v, invoice_payment_ids=[...],
                                         gross_amount=x, fee_amount=y, fee_vat=z)
        svc.validate(plan)            # raises ValueError on coverage gap

        # Apply (writes SettlementLine rows; caller commits):
        svc.allocate(voucher=v, invoice_payment_ids=[...],
                     gross_amount=x, fee_amount=y, fee_vat=z)

        # Cancel (deletes SettlementLine rows; caller commits):
        svc.unallocate(voucher=v)
    """

    # ------------------------------------------------------------------
    # build_allocation_plan — pure calculation, zero DB writes
    # ------------------------------------------------------------------

    def build_allocation_plan(
        self,
        *,
        voucher: Voucher,
        invoice_payment_ids: list[int],
        gross_amount: float,
        fee_amount: float = 0.0,
        fee_vat: float = 0.0,
    ) -> AllocationPlan:
        """Compute FIFO allocation of gross_amount across IPs — no DB writes.

        Algorithm:
          1. Fetch IPs, sort oldest-first (ties by id).
          2. For each IP, compute remaining unsettled balance (IP.amount minus
             any existing approved SettlementLine rows).
          3. Allocate min(remaining, remaining_gross) to this IP.
          4. Prorate commission and VAT by (IP.amount / total_ip_amounts).

        The approved-only filter on existing SettlementLines mirrors the guard
        added after incident AV-2026-00133 (phantom-settled IPs from cancelled
        vouchers AV-130/131/132 whose SettlementLines were not cleaned up).
        cancel_voucher() now deletes SettlementLines via unallocate(), so this
        filter is redundant for new data but retained for historical safety.
        """
        if not invoice_payment_ids:
            return AllocationPlan(
                voucher_id=voucher.id,
                gross_amount=round(float(gross_amount), 2),
                lines=[],
                unallocated_remainder=round(float(gross_amount), 2),
            )

        ip_rows = (
            InvoicePayment.query
            .filter(InvoicePayment.id.in_(invoice_payment_ids))
            .all()
        )
        # Oldest first; payments of one moment (an invoice paid in parts) by
        # id, so the order never depends on how the database returns the rows.
        ip_rows = sorted(ip_rows, key=lambda x: (x.created_at or datetime.min, x.id))

        # Approved-only settled amounts (excludes phantom rows from cancelled vouchers)
        all_ids = [ip.id for ip in ip_rows]
        prev_settled: dict[int, float] = {}
        if all_ids:
            sl_rows = (
                db.session.query(
                    SettlementLine.invoice_payment_id,
                    func.coalesce(func.sum(SettlementLine.amount_settled), 0.0),
                )
                .join(Voucher, Voucher.id == SettlementLine.voucher_id)
                .filter(SettlementLine.invoice_payment_id.in_(all_ids))
                .filter(Voucher.status == 'approved')
                .group_by(SettlementLine.invoice_payment_id)
                .all()
            )
            prev_settled = {r[0]: round(float(r[1]), 2) for r in sl_rows}

        # Prorate commission/VAT by consumed-amount fraction of gross_amount.
        # Using ip_amt/ip_total would fail when ip_total ≠ gross_amount (e.g.
        # backfill passes all IPs at once, making ip_total >> gross_amount and
        # distributing only a tiny fraction of the fee). amount_to_allocate/gross
        # distributes exactly fee_amount regardless of how many IPs are passed.
        _gross = float(gross_amount) or 1.0

        remaining_gross = round(float(gross_amount), 2)
        lines: list[AllocationLine] = []

        for ip in ip_rows:
            if remaining_gross <= 0.005:
                # gross_amount exhausted — remaining IPs stay pending for next cycle
                break
            ip_amt = round(float(ip.amount or 0), 2)
            already_settled = prev_settled.get(ip.id, 0.0)
            ip_remaining = round(ip_amt - already_settled, 2)
            if ip_remaining <= 0.005:
                continue
            amount_to_allocate = round(min(ip_remaining, remaining_gross), 2)
            ratio = amount_to_allocate / _gross
            lines.append(AllocationLine(
                invoice_payment_id=ip.id,
                amount_to_allocate=amount_to_allocate,
                commission=round(float(fee_amount) * ratio, 2),
                commission_vat=round(float(fee_vat) * ratio, 2),
            ))
            remaining_gross = round(remaining_gross - amount_to_allocate, 2)

        return AllocationPlan(
            voucher_id=voucher.id,
            gross_amount=round(float(gross_amount), 2),
            lines=lines,
            unallocated_remainder=remaining_gross,
        )

    # ------------------------------------------------------------------
    # validate — raises ValueError if plan cannot be applied
    # ------------------------------------------------------------------

    def validate(self, plan: AllocationPlan) -> None:
        """Raise ValueError if coverage is incomplete.

        A remainder > 0.01 means the provided invoice_payment_ids cannot absorb
        gross_amount, which would create a silent accounting gap (cash credited
        to clearing account with no matching SettlementLine trace). This was the
        root cause of the unexplained +6050 gap in AV-2026-00133.
        """
        if plan.unallocated_remainder > 0.01:
            raise ValueError(
                f'settlement_line_coverage_mismatch:'
                f'requested={plan.gross_amount:.2f},'
                f'unallocated={plan.unallocated_remainder:.2f}'
            )

    # ------------------------------------------------------------------
    # allocate — CREATE SettlementLine rows (caller commits)
    # ------------------------------------------------------------------

    def allocate(
        self,
        *,
        voucher: Voucher,
        invoice_payment_ids: list[int],
        gross_amount: float,
        fee_amount: float = 0.0,
        fee_vat: float = 0.0,
    ) -> AllocationPlan:
        """Create SettlementLine rows linking invoice_payment_ids to voucher.

        INVARIANT: append-only. Never updates existing SettlementLine rows.

        Returns the AllocationPlan that was applied.
        Raises ValueError (via validate()) if coverage is incomplete.
        Caller is responsible for db.session.commit().
        """
        plan = self.build_allocation_plan(
            voucher=voucher,
            invoice_payment_ids=invoice_payment_ids or [],
            gross_amount=gross_amount,
            fee_amount=fee_amount,
            fee_vat=fee_vat,
        )
        self.validate(plan)

        for line in plan.lines:
            db.session.add(SettlementLine(
                voucher_id=voucher.id,
                invoice_payment_id=line.invoice_payment_id,
                amount_settled=line.amount_to_allocate,
                commission=line.commission,
                commission_vat=line.commission_vat,
            ))

        db.session.flush()
        created_total = float(
            db.session.query(func.coalesce(func.sum(SettlementLine.amount_settled), 0.0))
            .filter(SettlementLine.voucher_id == voucher.id)
            .scalar()
            or 0.0
        )
        if abs(created_total - round(float(gross_amount), 2)) > 0.01:
            raise ValueError(
                f'settlement_lines_db_mismatch:'
                f'created={created_total:.2f},expected={gross_amount:.2f}'
            )

        return plan

    # ------------------------------------------------------------------
    # unallocate — DELETE SettlementLine rows (caller commits)
    # ------------------------------------------------------------------

    def unallocate(self, voucher: Voucher) -> int:
        """Delete all SettlementLine rows for a voucher.

        Called by cancel_voucher() to return IPs to the pending pool.
        Without this, cancelled vouchers leave phantom-settled IPs that the
        scheduler can no longer see as pending (incident AV-2026-00223, 2026-06-29,
        5 payments, 21,770 SAR stuck).

        Returns count of deleted rows.
        Caller is responsible for db.session.commit().
        """
        count = SettlementLine.query.filter_by(voucher_id=voucher.id).delete(
            synchronize_session=False
        )
        return int(count)
