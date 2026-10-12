"""allocation_repair_service.py — Repairs SettlementLine gaps in existing vouchers.

ARCHITECTURE:
    AllocationRepairService builds on AllocationService (the Single Writer).
    It never writes SettlementLines directly — all writes go through
    AllocationService.allocate() and AllocationService.unallocate().

    This is the lesson from memo_account_id:
    build SSoT first (AllocationService), then repair tools on top.

WHAT IT CAN FIX:
    Vouchers that exist but whose SettlementLine totals are less than
    voucher.amount_cash.  Repair = unallocate(v) + allocate(v, all_ips).

WHAT IT CANNOT FIX:
    IPs with no matching voucher at all (true accounting gap — the scheduler
    must create a new voucher first, then this service can link the IPs to it).

TYPICAL CAUSE OF REPAIRABLE GAPS:
    Scheduler guard `if clearing_balance <= 0: _skip()` fires when older
    backlog is settled using the current day's money.  The voucher for the
    current day either has too few SettlementLines or none at all, even
    though money reached the bank.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, date as date_type, timedelta

from sqlalchemy import func

from models import (
    db, SafeBox, PaymentMethod, InvoicePayment,
    Voucher, VoucherAccountLine, SettlementLine,
)
from allocation_service import AllocationService, AllocationPlan


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------

@dataclass
class RepairResult:
    """Outcome of repairing one voucher."""
    voucher_id: int
    voucher_number: str
    lines_deleted: int
    plan: AllocationPlan
    error: str | None = None

    @property
    def lines_created(self) -> int:
        return len(self.plan.lines)

    @property
    def is_repaired(self) -> bool:
        """True when fully covered and no exception was raised during repair."""
        return self.error is None and self.plan.is_fully_covered


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

# Clearing settlements whose untraced part is accepted -- {voucher number: the gap}
# (stage-4 item 10, CLEAR-001; the owner, 12 Oct 2026). They moved money from
# collection to the Riyadh bank, and no payment can be traced to these parts;
# the books are consistent (each collection account's balance equals what its
# unsettled payments owe, 11 Oct backup), and a reversal would move the main
# bank and re-open receivables already collected. Not repaired again -- only
# while the gap is this one: one that moves is incomplete again.
ACCEPTED_UNTRACEABLE = {
    'AV-2026-00098': 2105.0,   # تمارا: 2,105 من 3,000
    'AV-2026-00124': 895.0,    # تمارا: كلها
    'AV-2026-00133': 6050.0,   # مدى: 6,050 من 19,710
}


class AllocationRepairService:
    """Repairs SettlementLine gaps in approved clearing_settlement vouchers.

    Usage:
        svc = AllocationRepairService()

        # Inspect (no writes):
        gaps = svc.find_incomplete_vouchers(safe_box=sb)

        # Repair one voucher (caller flushes + commits):
        ip_pool = [ip.id for ip in ...]
        result = svc.repair_voucher(voucher=v, ip_pool=ip_pool)
        db.session.flush()

        # Repair all incomplete vouchers for a safe box (caller commits):
        results = svc.repair_safe_box(safe_box=sb)
        db.session.commit()
    """

    def __init__(self) -> None:
        self._svc = AllocationService()

    # ------------------------------------------------------------------
    # find_incomplete_vouchers — read only
    # ------------------------------------------------------------------

    def find_incomplete_vouchers(self, *, safe_box: SafeBox, accepted=None) -> list[Voucher]:
        """Return approved clearing_settlement vouchers with SettlementLine deficit.

        A voucher is "incomplete" when:
            sum(SettlementLine.amount_settled for lines on this voucher)
            < voucher.amount_cash − 0.01  (tolerance for rounding)

        -- unless its gap is one ACCEPTED_UNTRACEABLE holds, as measured.
        """
        accepted = ACCEPTED_UNTRACEABLE if accepted is None else accepted
        if not safe_box.account_id:
            return []

        vouchers = (
            Voucher.query
            .filter(Voucher.reference_type == 'clearing_settlement')
            .filter(Voucher.status == 'approved')
            .join(VoucherAccountLine, VoucherAccountLine.voucher_id == Voucher.id)
            .filter(VoucherAccountLine.account_id == safe_box.account_id)
            .order_by(Voucher.date.asc(), Voucher.id.asc())
            .distinct()
            .all()
        )

        incomplete = []
        for v in vouchers:
            total_settled = (
                db.session.query(
                    func.coalesce(func.sum(SettlementLine.amount_settled), 0.0)
                )
                .filter(SettlementLine.voucher_id == v.id)
                .scalar()
            ) or 0.0
            gap = round(float(v.amount_cash or 0) - round(float(total_settled), 2), 2)
            if gap > 0.01 and abs(gap - accepted.get(v.voucher_number, -1.0)) > 0.01:
                incomplete.append(v)

        return incomplete

    # ------------------------------------------------------------------
    # repair_voucher — writes via AllocationService
    # ------------------------------------------------------------------

    def repair_voucher(
        self,
        *,
        voucher: Voucher,
        ip_pool: list[int],
    ) -> RepairResult:
        """Unallocate then re-allocate a single voucher.

        ip_pool: all IP IDs for the clearing safe box (caller provides).
                 AllocationService re-sorts by created_at internally (FIFO).

        The caller MUST db.session.flush() after each repair_voucher() call
        so that the next voucher's allocate() sees accurate prev_settled.

        Raises ValueError if gross_amount cannot be fully covered by ip_pool.
        Caller is responsible for db.session.commit().
        """
        clearing_account_id = _get_clearing_account_id(voucher)
        fee_amount, fee_vat = _extract_fee_vat(voucher, clearing_account_id)

        # Delete existing SettlementLines for this voucher and flush so that
        # the subsequent allocate() sees a clean slate in prev_settled queries.
        deleted = self._svc.unallocate(voucher)
        db.session.flush()

        plan = self._svc.allocate(
            voucher=voucher,
            invoice_payment_ids=ip_pool,
            gross_amount=float(voucher.amount_cash or 0),
            fee_amount=fee_amount,
            fee_vat=fee_vat,
        )

        return RepairResult(
            voucher_id=voucher.id,
            voucher_number=voucher.voucher_number or str(voucher.id),
            lines_deleted=deleted,
            plan=plan,
        )

    # ------------------------------------------------------------------
    # repair_safe_box — orchestrates repair across a full safe box
    # ------------------------------------------------------------------

    def repair_safe_box(self, *, safe_box: SafeBox) -> list[RepairResult]:
        """Find and repair all incomplete vouchers for a clearing safe box.

        Processes incomplete vouchers in chronological order (oldest first)
        so that FIFO prev_settled accumulates correctly across repairs.

        Commits per-voucher: a failure on voucher N does not roll back the
        successful repairs of vouchers 1..N-1.  After a rollback, SQLAlchemy
        expires the remaining voucher objects so the next iteration re-fetches
        from DB, ensuring clean state.

        DATE BOUNDARY: each voucher only receives IPs whose created_at is on or
        before the voucher date + 2 days (1-day deposit delay + 1-day buffer).
        This prevents a May voucher from absorbing July IPs to fill its gap —
        the root cause of the AV-2026-00133 / -6,050 balance incident.

        Returns RepairResult for every attempted repair (check .is_repaired).
        """
        all_ips = (
            InvoicePayment.query
            .join(PaymentMethod, PaymentMethod.id == InvoicePayment.payment_method_id)
            .filter(PaymentMethod.default_safe_box_id == safe_box.id)
            .order_by(InvoicePayment.created_at.asc())
            .all()
        )
        # Pre-build a date map for O(1) cutoff filtering per voucher.
        ip_date_map: dict[int, datetime] = {
            ip.id: (ip.created_at or datetime.min) for ip in all_ips
        }
        all_ip_ids: list[int] = [ip.id for ip in all_ips]

        incomplete = self.find_incomplete_vouchers(safe_box=safe_box)
        results: list[RepairResult] = []

        for v in sorted(incomplete, key=lambda x: (x.date or datetime.min, x.id)):
            v_id = v.id
            v_number = v.voucher_number or str(v.id)
            v_gross = round(float(v.amount_cash or 0), 2)

            # Date-bounded IP pool: only IPs whose payment was collected on or
            # before this voucher's deposit date (voucher.date + 2-day window).
            # Prevents future-period IPs from filling historical voucher gaps.
            if v.date:
                v_dt = v.date if isinstance(v.date, datetime) else datetime(
                    v.date.year, v.date.month, v.date.day, 23, 59, 59
                )
                cutoff = v_dt + timedelta(days=2)
                ip_pool = [ip_id for ip_id in all_ip_ids
                           if ip_date_map.get(ip_id, datetime.min) <= cutoff]
            else:
                ip_pool = all_ip_ids

            try:
                result = self.repair_voucher(voucher=v, ip_pool=ip_pool)
                # flush → next voucher's allocate() sees these lines in prev_settled
                # commit → isolates this repair from failures on subsequent vouchers
                db.session.flush()
                db.session.commit()
                results.append(result)
            except Exception as exc:
                db.session.rollback()
                # After rollback, remaining v objects are expired (not detached) —
                # SQLAlchemy will re-SELECT them on next attribute access.
                results.append(RepairResult(
                    voucher_id=v_id,
                    voucher_number=v_number,
                    lines_deleted=0,
                    plan=AllocationPlan(
                        voucher_id=v_id,
                        gross_amount=v_gross,
                        lines=[],
                        unallocated_remainder=v_gross,
                    ),
                    error=str(exc),
                ))

        return results


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

def _get_clearing_account_id(voucher: Voucher) -> int | None:
    """Return the clearing account_id from a clearing_settlement voucher.

    The credit-side VoucherAccountLine is always the clearing account
    ("إقفال مستحقات التحصيل") — there is exactly one credit line per voucher.
    """
    for vl in voucher.account_lines.all():
        if vl.line_type == 'credit':
            return vl.account_id
    return None


def _extract_fee_vat(voucher: Voucher, clearing_account_id: int | None) -> tuple[float, float]:
    """Extract commission and VAT from debit-side VoucherAccountLines.

    Fee lines have 'عمولة' or 'commission' in their description.
    VAT lines additionally contain 'ضريبة' or 'vat'.
    The bank debit line has neither, so it is naturally excluded.
    """
    fee = 0.0
    fee_vat = 0.0
    for vl in voucher.account_lines.all():
        if vl.line_type == 'debit' and vl.account_id != clearing_account_id:
            desc = (vl.description or '').lower()
            if 'عمولة' in desc or 'commission' in desc:
                if 'ضريبة' in desc or 'vat' in desc:
                    fee_vat += float(vl.amount or 0)
                else:
                    fee += float(vl.amount or 0)
    return fee, fee_vat
