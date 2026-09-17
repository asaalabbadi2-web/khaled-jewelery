"""supplier_settlement_adjustment_service.py — closes small justified residuals
on a supplier's GL-derived balance.

ARCHITECTURE
    This service is an ORCHESTRATOR, not a posting engine.  It writes no
    JournalEntry, no JournalEntryLine, and no balance column.  The only path to
    an accounting effect is the canonical Voucher pipeline:

        SupplierSettlementAdjustment
              -> Voucher + VoucherAccountLine
              -> create_journal_entry_from_voucher()   (accounting/voucher_engine)
              -> JournalEntry + JournalEntryLine

    Single Writer      : the Voucher pipeline (this service never posts directly)
    Single Source      : JournalEntryLine, read via compute_live_supplier_balances()
    Atomic Transaction : one flush-and-verify unit; caller commits. Any failure
                         (including the closing invariant) raises, so a partial
                         effect is impossible.

THE LOAD-BEARING INVARIANT
    The direction of the entry is never expressed as a prose rule ("positive
    means X") that a future reader could invert.  It is expressed as a
    post-condition: after posting, re-running compute_live_supplier_balances()
    must return zero for the financial side and for every karat that was
    settled, within accounting precision.  _assert_supplier_closed() enforces
    it and rolls the whole operation back otherwise.

CASH AND WEIGHT ARE THE SAME MECHANISM
    A gold-weight residual is settled exactly like a cash residual — same sign
    rule, same direction derivation, same document — but it posts to the
    supplier's parallel memo (weight) account instead of the financial one, and
    it is never valued.  No gold price is read, no SAR conversion happens, no
    inventory moves, and no cost of sales is touched.  Grams are closed with
    grams.  Each karat is settled independently; karats are never merged.

    The memo account is reached through the chart of accounts, never derived:
    the voucher line carries the supplier's FINANCIAL account id, and the
    canonical resolver (_resolve_account_id_for_amount_type) redirects gold
    lines to the paired memo account via Account.memo_account_id.

MEASURING WEIGHT: MAIN KARAT
    Grams of different purity are not the same quantity, so policy limits are
    never applied to raw grams and karats are never added together. Both the
    per-operation tolerance and the monthly cap are measured in the system's
    configured Main Karat, through the existing canonical converter
    (pricing.karat_service.convert_to_main_karat) — no second conversion engine.

    This is a measurement normalization for eligibility and policy limits only.
    It is not a monetary valuation, and it never replaces the original-karat
    posting: the journal still carries each karat in its own column on the
    supplier's memo account, and Law 0 is proven per original karat.

WHAT THIS IS NOT
    Not a "zero the supplier" button.  A residual above the policy review
    threshold is refused outright (SupplierAccountReviewRequiredError) — a large
    balance is an unexplained accounting fact, not a settlement difference.

CLOCK DISCIPLINE (ADR-015)
    Every decision method takes `now` as a parameter and this module makes no
    wall-clock call of its own.  The caller (route, worker, test) reads the
    clock once at the boundary and passes the value down, so a settlement can
    be replayed at any timestamp.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import func

from accounting.mappings import get_account_id_for_mapping
from accounting.voucher_engine import (
    _append_safe_transactions_for_voucher,
    _update_account_balances_from_journal_lines,
    create_journal_entry_from_voucher,
    generate_voucher_number,
)
from models import (
    Account,
    Invoice,
    JournalEntry,
    JournalEntryLine,
    Supplier,
    SupplierSettlementAdjustment,
    SupplierSettlementPolicy,
    Voucher,
    VoucherAccountLine,
    db,
)
from party_account_service import ensure_supplier_accounts
from pricing.karat_service import convert_to_main_karat
from services.party_live_balances import compute_live_supplier_balances


# ─────────────────────────────────────────────────────────────────────────────
# Accounting precision — LAW (code), not policy.
#
# These are the limits of what the ledger can represent, not a business choice.
# They are deliberately NOT the same thing as SupplierSettlementPolicy
# tolerances (which are POLICY and live in the database): a residual may be
# within accounting precision yet far outside what finance permits to be
# written off, and vice versa.
# ─────────────────────────────────────────────────────────────────────────────

CASH_EPSILON = 0.01      # SAR — matches the ledger's 2-decimal cash precision
WEIGHT_EPSILON = 0.001   # grams — matches je_engine_v2's balance tolerance

# Posting precision. Cash is a 2-decimal currency; weight is settled to the
# gram precision the ledger actually reasons about (WEIGHT_EPSILON).
CASH_PRECISION = 2
WEIGHT_PRECISION = 3

# Written to Voucher.reference_type, which is String(20) — shorter than the
# document's own name. PostgreSQL rejects an over-length value outright while
# SQLite silently accepts it, so the limit is enforced by a test rather than
# discovered on first posting. Widening the shared column for one domain would
# be the wrong trade.
VOUCHER_REFERENCE_TYPE = 'supplier_settlement'

# AccountingMapping coordinates. The GL accounts themselves are configuration:
# this module never hardcodes an account number.
SETTLEMENT_OPERATION_TYPE = 'تسوية_مورد'
ACCOUNT_TYPE_SETTLEMENT_EXPENSE = 'supplier_settlement_expense'
ACCOUNT_TYPE_SETTLEMENT_INCOME = 'supplier_settlement_income'
ACCOUNT_TYPE_WEIGHT_SETTLEMENT_EXPENSE = 'supplier_weight_settlement_expense'
ACCOUNT_TYPE_WEIGHT_SETTLEMENT_INCOME = 'supplier_weight_settlement_income'

# compute_live_supplier_balances() key -> VoucherAccountLine.karat
_KARAT_KEYS = {'18k': 18.0, '21k': 21.0, '22k': 22.0, '24k': 24.0}

# The eligibility check that is not "ineligible pending cleanup" but a refusal
# to use this instrument at all. Named once because two callers depend on it
# being the same check: post() raises on it before anything else, and preview()
# reports it before anything else.
REVIEW_GATE_CHECK = 'below_review_threshold'

# Reported by preview() when the stored snapshot no longer matches the ledger.
# It is not an EligibilityCheck — post() refuses on it separately — so it
# borrows the route layer's existing error string rather than a new name.
REASON_SNAPSHOT_MISMATCH = 'snapshot_mismatch'

# Statuses in which the stored snapshot is still a promise post() must honour.
# In any other status the comparison is moot: post() will never run again.
_SNAPSHOT_HONOURED_STATUSES = frozenset({
    SupplierSettlementAdjustment.STATUS_DRAFT,
    SupplierSettlementAdjustment.STATUS_APPROVED,
})


# ─────────────────────────────────────────────────────────────────────────────
# Errors
# ─────────────────────────────────────────────────────────────────────────────

class SupplierSettlementError(Exception):
    """Base class for every refusal this service can issue."""


class MissingAccountingMappingError(SupplierSettlementError):
    """No GL account is configured for the required settlement account type."""


class NotEligibleError(SupplierSettlementError):
    """One or more eligibility checks failed."""

    def __init__(self, message: str, failed_checks: list | None = None):
        super().__init__(message)
        self.failed_checks = failed_checks or []


class SnapshotMismatchError(SupplierSettlementError):
    """The supplier balance moved between draft and post; nothing was written."""


class SupplierAccountReviewRequiredError(SupplierSettlementError):
    """Residual exceeds the review threshold — needs investigation, not a write-off.

    Carries the figures the caller needs to tell the user what to review. It
    describes a refusal only: nothing is written, nothing is recalculated, and
    no review workflow is started — that is a separate feature.
    """

    REASON_RESIDUAL_ABOVE_REVIEW_THRESHOLD = 'RESIDUAL_ABOVE_REVIEW_THRESHOLD'

    def __init__(
        self,
        message: str,
        *,
        supplier_id: int,
        current_cash_residual: float,
        current_weight_residual: dict,
        review_threshold: float,
        reason: str = REASON_RESIDUAL_ABOVE_REVIEW_THRESHOLD,
    ):
        super().__init__(message)
        self.supplier_id = int(supplier_id)
        self.current_cash_residual = float(current_cash_residual)
        self.current_weight_residual = dict(current_weight_residual or {})
        self.review_threshold = float(review_threshold)
        self.reason = reason

    def to_dict(self) -> dict:
        return {
            'error': 'supplier_account_review_required',
            'reason': self.reason,
            'supplier_id': self.supplier_id,
            'current_cash_residual': self.current_cash_residual,
            'current_weight_residual': self.current_weight_residual,
            'review_threshold': self.review_threshold,
            'message': str(self),
        }


class SettlementInvariantViolation(SupplierSettlementError):
    """The ledger did not move exactly as the settlement intended. Transaction void.

    Carries the three figures that make the violation self-explanatory, so a
    caller (or a test) can reason about it numerically instead of parsing text.
    """

    def __init__(
        self,
        message: str,
        *,
        balance_before: float | None = None,
        balance_after: float | None = None,
        expected_after: float | None = None,
    ):
        super().__init__(message)
        self.balance_before = balance_before
        self.balance_after = balance_after
        self.expected_after = expected_after


class ManagerApprovalRequiredError(SupplierSettlementError):
    """This reason code requires a manager to approve."""


# ─────────────────────────────────────────────────────────────────────────────
# Value objects
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class EligibilityCheck:
    name: str
    passed: bool
    detail: str = ''


@dataclass(frozen=True)
class SettlementSnapshot:
    """A point-in-time reading of the supplier's GL-derived balance.

    `financial` is debit-positive, exactly as compute_live_supplier_balances()
    returns it: positive means the supplier owes us, negative means we owe the
    supplier.  No sign is reinterpreted anywhere in this module.
    """
    financial: float
    by_karat: dict
    captured_at: datetime
    schema_version: int = SupplierSettlementAdjustment.SNAPSHOT_SCHEMA_VERSION

    @property
    def open_karats(self) -> dict:
        return {k: v for k, v in self.by_karat.items() if abs(v) > WEIGHT_EPSILON}

    @property
    def has_financial_residual(self) -> bool:
        return abs(self.financial) > CASH_EPSILON


@dataclass(frozen=True)
class EligibilityResult:
    supplier_id: int
    snapshot: SettlementSnapshot
    checks: list = field(default_factory=list)
    policy: SupplierSettlementPolicy | None = None

    @property
    def failed(self) -> list:
        return [c for c in self.checks if not c.passed]

    @property
    def is_eligible(self) -> bool:
        return not self.failed


@dataclass(frozen=True)
class SettlementPreview:
    """What post() would decide right now, computed without writing anything.

    Every figure is carried, not derived here: the snapshot comes from
    recalculate(), the verdict from check_eligibility(), the normalised weight
    from _main_karat_equivalent(), the month's usage from the same period
    helpers the cap check uses. This object is a report, not a second engine.

    `snapshot` is the LIVE reading — the one post() would act on — not the
    document's stored snapshot. The two are compared in `stored_snapshot_matches`
    so a caller can see drift before it becomes a refusal.
    """
    adjustment_id: int
    supplier_id: int
    status: str
    computed_at: datetime
    snapshot: SettlementSnapshot
    main_karat_equivalent: float
    stored_snapshot_matches: bool
    eligibility: EligibilityResult
    cash_consumed: float
    weight_consumed: float
    # Carried from the service's _period_key(), never re-derived here: the
    # month boundary is a business rule and it has one owner.
    period_key: str
    policy: SupplierSettlementPolicy | None = None
    blocking_reason: tuple | None = None

    @property
    def is_eligible(self) -> bool:
        """Eligible means nothing blocks a post, drift included."""
        return self.blocking_reason is None

    @property
    def remaining_cash_cap(self) -> float | None:
        """Unclamped on purpose: a negative figure means a policy change left
        the month already over its ceiling, which the reader must see."""
        if self.policy is None:
            return None
        return round(
            float(self.policy.period_cap_cash) - self.cash_consumed, CASH_PRECISION
        )

    @property
    def remaining_weight_cap(self) -> float | None:
        if self.policy is None:
            return None
        return round(float(self.policy.period_cap_weight) - self.weight_consumed, 6)

    def to_dict(self) -> dict:
        code, message = self.blocking_reason or (None, None)
        return {
            'adjustment_id': self.adjustment_id,
            'supplier_id': self.supplier_id,
            'status': self.status,
            'computed_at': self.computed_at.isoformat(),
            'period_key': self.period_key,

            # Live balance — debit-positive, exactly as the ledger reports it.
            'balance_before_financial': self.snapshot.financial,
            'balance_before_weight': dict(self.snapshot.by_karat),
            'main_karat_equivalent': self.main_karat_equivalent,

            'stored_snapshot_matches': self.stored_snapshot_matches,

            'eligibility': {
                'eligible': self.is_eligible,
                'blocking_reason': (
                    None if code is None else {'code': code, 'message': message}
                ),
                # The full ordered verdict, so a caller can show every gate
                # rather than only the first one that failed.
                'checks': [
                    {'name': c.name, 'passed': c.passed, 'detail': c.detail}
                    for c in self.eligibility.checks
                ],
            },

            'policy': None if self.policy is None else {
                'policy_id': self.policy.id,
                'tolerance_cash': float(self.policy.tolerance_cash),
                'tolerance_weight': float(self.policy.tolerance_weight),
                'period_cap_cash': float(self.policy.period_cap_cash),
                'period_cap_weight': float(self.policy.period_cap_weight),
                'review_threshold_cash': float(self.policy.review_threshold_cash),
                'cash_consumed': self.cash_consumed,
                'weight_consumed': self.weight_consumed,
                'remaining_cash_cap': self.remaining_cash_cap,
                'remaining_weight_cap': self.remaining_weight_cap,
            },
        }


# ─────────────────────────────────────────────────────────────────────────────
# Service
# ─────────────────────────────────────────────────────────────────────────────

class SupplierSettlementAdjustmentService:
    """Usage:

        svc = SupplierSettlementAdjustmentService()

        result = svc.check_eligibility(supplier, now=now)       # read-only
        sad    = svc.create_draft(supplier=supplier, reason_code=..., ...)
        sad    = svc.approve(sad=sad, approved_by='...', now=now)
        sad    = svc.post(sad=sad, posted_by='...', now=now)    # caller commits
    """

    # ── Read-only inspection ────────────────────────────────────────────────

    def recalculate(self, supplier: Supplier, *, now: datetime) -> SettlementSnapshot:
        """Read the supplier's balance fresh from the ledger.

        This is the ONLY balance source in this module. Denormalised columns
        (Supplier.balance_*, Account.balance_*, Supplier.gold_balance_weight)
        are never read and never written.
        """
        balances = compute_live_supplier_balances([supplier])
        row = balances.get(int(supplier.id)) or {}
        return SettlementSnapshot(
            financial=round(float(row.get('cash') or 0.0), 2),
            by_karat={
                key: round(float(row.get(key) or 0.0), 6)
                for key in _KARAT_KEYS
            },
            captured_at=now,
        )

    def check_eligibility(
        self,
        supplier: Supplier,
        *,
        now: datetime,
        exclude_adjustment_id: int | None = None,
        policy: SupplierSettlementPolicy | None = None,
    ) -> EligibilityResult:
        """Run every eligibility check. Writes nothing.

        At draft time this is advisory; post() re-runs it under a row lock and
        that run is the one that decides.
        """
        snapshot = self.recalculate(supplier, now=now)
        if policy is None:
            policy = self._resolve_policy(now)

        checks: list[EligibilityCheck] = [
            self._check_no_unpaid_invoices(supplier),
            self._check_no_unposted_journal_entries(supplier),
            self._check_no_pending_vouchers(supplier),
            self._check_no_other_open_adjustments(supplier, exclude_adjustment_id),
            self._check_has_residual(snapshot),
        ]

        if policy is not None:
            checks.extend([
                self._check_below_review_threshold(snapshot, policy),
                self._check_within_operation_tolerance(snapshot, policy),
                self._check_within_period_cap(supplier, snapshot, policy, now, exclude_adjustment_id),
            ])
        else:
            checks.append(EligibilityCheck(
                name='policy_configured',
                passed=False,
                detail='لا توجد SupplierSettlementPolicy نافذة في هذا التاريخ.',
            ))

        return EligibilityResult(
            supplier_id=int(supplier.id),
            snapshot=snapshot,
            checks=checks,
            policy=policy,
        )

    def preview(
        self,
        *,
        sad: SupplierSettlementAdjustment,
        now: datetime,
    ) -> SettlementPreview:
        """Answer "what would post() decide right now?" — writing nothing.

        Every figure comes from the same calls post() makes under its row lock:
        check_eligibility() for the verdict, _main_karat_equivalent() for the
        normalised weight, _period_consumption()/_period_weight_consumption()
        for the month's allowance, _snapshot_drift() for the snapshot
        comparison, and _blocking_reason() for the order those refusals are
        decided in. Nothing is computed a second way here, so a preview that
        says "eligible" and a post() that refuses cannot disagree unless the
        ledger itself moved between the two calls.

        Read-only in the strict sense: no voucher, no journal entry, no state
        transition, no snapshot refresh, no allowance consumed. A snapshot
        drift in particular is reported and never acted on — post() remains the
        only place that kicks a document back to draft.
        """
        supplier = sad.supplier
        result = self.check_eligibility(
            supplier,
            now=now,
            exclude_adjustment_id=sad.id,
        )
        current = result.snapshot

        # Only meaningful while post() could still run against this document.
        drift = (
            self._snapshot_drift(sad, current)
            if sad.status in _SNAPSHOT_HONOURED_STATUSES
            else None
        )

        return SettlementPreview(
            adjustment_id=int(sad.id),
            supplier_id=int(supplier.id),
            status=sad.status,
            computed_at=now,
            snapshot=current,
            # The same quantity the tolerance and cap checks compare against —
            # open karats only, magnitudes summed after conversion.
            main_karat_equivalent=self._main_karat_equivalent(current.open_karats),
            stored_snapshot_matches=(drift is None),
            eligibility=result,
            cash_consumed=self._period_consumption(supplier, now, sad.id),
            weight_consumed=self._period_weight_consumption(supplier, now, sad.id),
            period_key=self._period_key(now),
            policy=result.policy,
            blocking_reason=self._blocking_reason(result, drift),
        )

    # ── Lifecycle ────────────────────────────────────────────────────────────

    def create_draft(
        self,
        *,
        supplier: Supplier,
        reason_code: str,
        created_by: str,
        now: datetime,
        note: str | None = None,
    ) -> SupplierSettlementAdjustment:
        """Create a draft with its balance snapshot. Writes no accounting."""
        if reason_code not in SupplierSettlementAdjustment.VALID_REASON_CODES:
            raise ValueError(
                f'reason_code غير صالح: {reason_code!r}. '
                f'المسموح: {sorted(SupplierSettlementAdjustment.VALID_REASON_CODES)}'
            )
        if reason_code in SupplierSettlementAdjustment.REASONS_REQUIRING_MANAGER_APPROVAL:
            if not (note or '').strip():
                raise ValueError(f'السبب {reason_code} يستلزم ملاحظة مكتوبة.')

        result = self.check_eligibility(supplier, now=now)
        # Same typed refusals as post(): a residual needing review is not a
        # draft waiting for cleanup, and the caller must be able to tell them
        # apart without reading a message.
        self._raise_if_review_required(result)
        if not result.is_eligible:
            raise NotEligibleError(
                'المورد غير مؤهل للتسوية: '
                + ' · '.join(f'{c.name}: {c.detail}' for c in result.failed),
                failed_checks=result.failed,
            )

        sad = SupplierSettlementAdjustment(
            adjustment_number=self._next_adjustment_number(now),
            supplier_id=int(supplier.id),
            status=SupplierSettlementAdjustment.STATUS_DRAFT,
            reason_code=reason_code,
            note=note,
            snapshot_schema_version=SupplierSettlementAdjustment.SNAPSHOT_SCHEMA_VERSION,
            balance_before_financial=result.snapshot.financial,
            balance_before_weight=SupplierSettlementAdjustment._dump_weight(result.snapshot.by_karat),
            snapshot_captured_at=result.snapshot.captured_at,
            created_by=created_by,
        )
        db.session.add(sad)
        db.session.flush()
        return sad

    def refresh_snapshot(
        self,
        *,
        sad: SupplierSettlementAdjustment,
        now: datetime,
    ) -> SupplierSettlementAdjustment:
        """Re-capture the snapshot on a draft after the balance moved."""
        if sad.status != SupplierSettlementAdjustment.STATUS_DRAFT:
            raise ValueError(
                f'إعادة حساب اللقطة متاحة في حالة draft فقط (الحالة: {sad.status}).'
            )
        snapshot = self.recalculate(sad.supplier, now=now)
        sad.balance_before_financial = snapshot.financial
        sad.balance_before_weight = SupplierSettlementAdjustment._dump_weight(snapshot.by_karat)
        sad.snapshot_captured_at = snapshot.captured_at
        db.session.flush()
        return sad

    def approve(
        self,
        *,
        sad: SupplierSettlementAdjustment,
        approved_by: str,
        now: datetime,
        is_manager: bool = False,
    ) -> SupplierSettlementAdjustment:
        """Approve a draft. Still writes no accounting."""
        if sad.reason_code in SupplierSettlementAdjustment.REASONS_REQUIRING_MANAGER_APPROVAL:
            if not is_manager:
                raise ManagerApprovalRequiredError(
                    f'السبب {sad.reason_code} يستلزم اعتماد مدير.'
                )

        sad._transition(SupplierSettlementAdjustment.STATUS_APPROVED)
        sad.approved_by = approved_by
        sad.approved_at = now
        sad.approved_by_manager = bool(is_manager)
        db.session.flush()
        return sad

    def post(
        self,
        *,
        sad: SupplierSettlementAdjustment,
        posted_by: str,
        now: datetime,
    ) -> SupplierSettlementAdjustment:
        """Post the adjustment. The caller owns the commit.

        Everything that matters happens here, in this order:
          1. Lock the adjustment row.
          2. Re-read the balance and re-run every eligibility check — the draft's
             verdict is never trusted.
          3. Compare against the snapshot; a drift kicks the document back to
             draft and writes nothing.
          4. Build the Voucher and post through the canonical pipeline.
          5. Verify the supplier balance is now zero. If not, raise — which
             rolls back everything, including the journal entry.
        """
        locked = (
            SupplierSettlementAdjustment.query
            .with_for_update()
            .get(sad.id)
        )
        if locked is None:
            raise ValueError(f'SupplierSettlementAdjustment id={sad.id} غير موجودة.')
        sad = locked

        if sad.status != SupplierSettlementAdjustment.STATUS_APPROVED:
            raise ValueError(
                f'لا يمكن ترحيل تسوية بحالة {sad.status!r} — المطلوب: approved.'
            )
        if sad.voucher_id is not None:
            raise ValueError(
                f'التسوية {sad.adjustment_number} مرتبطة بسند مسبقاً (voucher_id={sad.voucher_id}).'
            )

        supplier = sad.supplier
        policy = self._resolve_policy(now)

        # ── Re-validate from scratch under the lock ──────────────────────────
        result = self.check_eligibility(
            supplier,
            now=now,
            exclude_adjustment_id=sad.id,
            policy=policy,
        )

        # A residual above the review threshold is a separate refusal: it is not
        # "ineligible pending cleanup", it is the wrong instrument entirely.
        self._raise_if_review_required(result)

        current = result.snapshot

        # ── Snapshot comparison ──────────────────────────────────────────────
        # Runs before the general eligibility verdict on purpose: if the balance
        # moved at all — including all the way to zero — the actionable answer is
        # "recalculate", and the document must land back in a state where that is
        # possible. A general eligibility failure, by contrast, leaves the
        # document approved: its snapshot is still valid, the blocker is elsewhere.
        drift = self._snapshot_drift(sad, current)
        if drift is not None:
            self._kick_back_to_draft(sad)
            raise SnapshotMismatchError(drift)

        if not result.is_eligible:
            raise NotEligibleError(
                'فشل إعادة فحص الأهلية عند الترحيل — لم يُكتب أي قيد: '
                + ' · '.join(f'{c.name}: {c.detail}' for c in result.failed),
                failed_checks=result.failed,
            )

        # ── Post through the canonical pipeline ──────────────────────────────
        settled_karats = current.open_karats
        voucher = self._build_and_post_voucher(
            sad=sad,
            supplier=supplier,
            residual_cash=current.financial,
            residual_by_karat=settled_karats,
            posted_by=posted_by,
            now=now,
            description=(
                f'تسوية فرق حساب مورد [{sad.reason_code}] — {sad.adjustment_number}'
            ),
        )

        sad._transition(SupplierSettlementAdjustment.STATUS_POSTED)
        sad.posted_by = posted_by
        sad.posted_at = now
        sad.policy_id = policy.id if policy else None
        sad.period_key = self._period_key(now)
        sad.posted_amount_cash = current.financial
        sad.posted_amount_weight = SupplierSettlementAdjustment._dump_weight(settled_karats)
        sad.voucher_id = voucher.id
        sad.journal_entry_id = voucher.journal_entry_id
        db.session.flush()

        # ── The invariant that makes the direction rule self-proving ─────────
        # Identity 1 proves the ledger moved by exactly -residual, on the cash
        # side and on every karat; identity 2 proves that movement closed them.
        after = self._verify_ledger_effect(
            supplier,
            before=current,
            expected_cash_effect=-current.financial,
            expected_weight_effect={k: -v for k, v in settled_karats.items()},
            now=now,
            context=sad.adjustment_number,
        )
        self._assert_closed(after, context=sad.adjustment_number)

        return sad

    def reverse(
        self,
        *,
        sad: SupplierSettlementAdjustment,
        reversed_by: str,
        reason: str,
        now: datetime,
    ) -> SupplierSettlementAdjustment:
        """Reverse a posted adjustment by posting an opposite one.

        The original is never edited or deleted: it transitions to `reversed`
        and a new adjustment carrying reversal_of_id holds the opposite entry.
        """
        locked = (
            SupplierSettlementAdjustment.query
            .with_for_update()
            .get(sad.id)
        )
        if locked is None:
            raise ValueError(f'SupplierSettlementAdjustment id={sad.id} غير موجودة.')
        sad = locked

        if sad.status != SupplierSettlementAdjustment.STATUS_POSTED:
            raise ValueError(
                f'لا يمكن عكس تسوية بحالة {sad.status!r} — المطلوب: posted.'
            )
        if not (reason or '').strip():
            raise ValueError('سبب العكس إلزامي.')

        existing = (
            SupplierSettlementAdjustment.query
            .filter_by(reversal_of_id=sad.id)
            .first()
        )
        if existing is not None:
            raise ValueError(
                f'التسوية {sad.adjustment_number} معكوسة مسبقاً '
                f'بالوثيقة {existing.adjustment_number}.'
            )

        supplier = sad.supplier
        original_amount = float(sad.posted_amount_cash or 0.0)
        original_weight = sad.posted_amount_weight_by_karat
        before = self.recalculate(supplier, now=now)

        reversal = SupplierSettlementAdjustment(
            adjustment_number=self._next_adjustment_number(now),
            supplier_id=sad.supplier_id,
            status=SupplierSettlementAdjustment.STATUS_APPROVED,
            reason_code=sad.reason_code,
            note=f'عكس {sad.adjustment_number}: {reason}',
            snapshot_schema_version=SupplierSettlementAdjustment.SNAPSHOT_SCHEMA_VERSION,
            balance_before_financial=0.0,
            balance_before_weight=SupplierSettlementAdjustment._dump_weight({}),
            snapshot_captured_at=now,
            reversal_of_id=sad.id,
            created_by=reversed_by,
            approved_by=reversed_by,
            approved_at=now,
            approved_by_manager=bool(sad.approved_by_manager),
        )
        db.session.add(reversal)
        db.session.flush()

        # Opposite sign of what the original posted, on both sides: passing the
        # negated residuals through the same builder produces the mirrored
        # debit/credit pairs, cash and every settled karat alike.
        reversed_weight = {k: -float(v) for k, v in original_weight.items()}
        voucher = self._build_and_post_voucher(
            sad=reversal,
            supplier=supplier,
            residual_cash=-original_amount,
            residual_by_karat=reversed_weight,
            posted_by=reversed_by,
            now=now,
            description=(
                f'عكس تسوية فرق حساب مورد — {reversal.adjustment_number} '
                f'(عكس {sad.adjustment_number})'
            ),
        )

        reversal._transition(SupplierSettlementAdjustment.STATUS_POSTED)
        reversal.posted_by = reversed_by
        reversal.posted_at = now
        reversal.period_key = self._period_key(now)
        reversal.policy_id = sad.policy_id
        reversal.posted_amount_cash = -original_amount
        reversal.posted_amount_weight = SupplierSettlementAdjustment._dump_weight(reversed_weight)
        reversal.voucher_id = voucher.id
        reversal.journal_entry_id = voucher.journal_entry_id

        sad._transition(SupplierSettlementAdjustment.STATUS_REVERSED)
        sad.reversed_by = reversed_by
        sad.reversed_at = now
        sad.reversal_reason = reason

        db.session.flush()

        # Identity 1 only: a reversal restores the residual on purpose, so
        # _assert_closed would be exactly the wrong assertion here.
        self._verify_ledger_effect(
            supplier,
            before=before,
            expected_cash_effect=original_amount,
            expected_weight_effect={k: float(v) for k, v in original_weight.items()},
            now=now,
            context=reversal.adjustment_number,
        )

        return reversal

    def cancel(
        self,
        *,
        sad: SupplierSettlementAdjustment,
        cancelled_by: str,
        reason: str,
        now: datetime,
    ) -> SupplierSettlementAdjustment:
        """Cancel a draft or approved adjustment. Posted ones must be reversed."""
        if sad.status == SupplierSettlementAdjustment.STATUS_POSTED:
            raise ValueError(
                f'التسوية {sad.adjustment_number} مرحّلة — استخدم reverse() بدل الإلغاء.'
            )
        sad._transition(SupplierSettlementAdjustment.STATUS_CANCELLED)
        sad.cancelled_by = cancelled_by
        sad.cancelled_at = now
        sad.cancellation_reason = reason
        db.session.flush()
        return sad

    # ── Posting internals ────────────────────────────────────────────────────

    def _build_and_post_voucher(
        self,
        *,
        sad: SupplierSettlementAdjustment,
        supplier: Supplier,
        residual_cash: float,
        residual_by_karat: dict,
        posted_by: str,
        now: datetime,
        description: str,
    ) -> Voucher:
        """Build the Voucher + lines and run the canonical posting pipeline.

        One direction rule serves both sides. Applied to cash it names the
        financial accounts; applied to a karat it names the weight accounts and
        the supplier's memo account — the amount stays in grams either way:

            residual > 0  supplier owes us   -> Cr supplier / Dr settlement expense
            residual < 0  we owe supplier    -> Dr supplier / Cr settlement income

        Each karat produces its own independent pair of lines. Karats are never
        summed together and never converted to SAR.
        """
        supplier_account_id = int(ensure_supplier_accounts(supplier).financial.id)

        cash_amount = round(abs(float(residual_cash or 0.0)), CASH_PRECISION)
        if cash_amount <= 0:
            cash_amount = 0.0

        karat_amounts: list[tuple[float, float, float]] = []  # (karat, signed, amount)
        for key, raw in (residual_by_karat or {}).items():
            karat = _KARAT_KEYS.get(key)
            if karat is None:
                continue
            signed = float(raw or 0.0)
            if abs(signed) <= WEIGHT_EPSILON:
                continue
            karat_amounts.append((karat, signed, round(abs(signed), WEIGHT_PRECISION)))

        if cash_amount <= 0 and not karat_amounts:
            raise ValueError('لا يوجد رصيد لتسويته.')

        voucher = Voucher(
            voucher_number=generate_voucher_number('adjustment', voucher_date=now),
            voucher_type='adjustment',
            date=now,
            description=description,
            status='approved',
            party_type='supplier',
            supplier_id=int(supplier.id),
            party_name=supplier.name,
            amount_cash=cash_amount,
            amount_gold=round(sum(a for _, _, a in karat_amounts), WEIGHT_PRECISION),
            reference_type=VOUCHER_REFERENCE_TYPE,
            reference_id=sad.id,
            reference_number=sad.adjustment_number,
            created_by=posted_by,
            approved_by=posted_by,
            approved_at=now,
        )
        db.session.add(voucher)
        db.session.flush()

        def _add_pair(*, signed, amount, amount_type, counter_account_id, karat=None, label):
            if signed > 0:
                supplier_line_type, counter_line_type = 'credit', 'debit'
            else:
                supplier_line_type, counter_line_type = 'debit', 'credit'

            # The supplier line always carries the FINANCIAL account id. For a
            # gold line the canonical resolver redirects it to the paired memo
            # account through Account.memo_account_id — the pairing is read from
            # the chart of accounts, never derived from the account number.
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=supplier_account_id,
                line_type=supplier_line_type,
                amount_type=amount_type,
                amount=amount,
                karat=karat,
                description=f'{description} — حساب المورد ({label})',
            ))
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=counter_account_id,
                line_type=counter_line_type,
                amount_type=amount_type,
                amount=amount,
                karat=karat,
                description=f'{description} — {label}',
            ))

        if cash_amount > 0:
            _add_pair(
                signed=float(residual_cash),
                amount=cash_amount,
                amount_type='cash',
                counter_account_id=self._resolve_settlement_account_id(
                    ACCOUNT_TYPE_SETTLEMENT_EXPENSE if residual_cash > 0
                    else ACCOUNT_TYPE_SETTLEMENT_INCOME
                ),
                label='تسوية نقدية',
            )

        for karat, signed, amount in karat_amounts:
            _add_pair(
                signed=signed,
                amount=amount,
                amount_type='gold',
                counter_account_id=self._resolve_weight_settlement_account_id(
                    ACCOUNT_TYPE_WEIGHT_SETTLEMENT_EXPENSE if signed > 0
                    else ACCOUNT_TYPE_WEIGHT_SETTLEMENT_INCOME
                ),
                karat=karat,
                label=f'تسوية وزن عيار {int(karat)}',
            )

        db.session.flush()

        journal_entry = create_journal_entry_from_voucher(voucher)
        if journal_entry is None:
            raise SettlementInvariantViolation(
                f'لم يُنشأ قيد محاسبي للتسوية {sad.adjustment_number}.'
            )

        journal_entry.is_posted = True
        journal_entry.is_draft = False
        journal_entry.posted_at = now
        journal_entry.posted_by = posted_by
        voucher.journal_entry_id = journal_entry.id
        db.session.flush()

        # Same post-JE sequence every other voucher call site performs. Not
        # wrapped in try/except: a failure here must roll the posting back
        # rather than leave GL and the sub-ledgers disagreeing.
        _append_safe_transactions_for_voucher(voucher, created_by=posted_by)
        _update_account_balances_from_journal_lines(journal_entry.lines or [])
        db.session.flush()

        return voucher

    def _kick_back_to_draft(self, sad: SupplierSettlementAdjustment) -> None:
        """Return an approved document to draft and void its approval.

        The approval was given for a balance that no longer exists, so it is
        cleared rather than left on the row: re-posting must pass through a
        fresh, explicit approval of the recalculated figure.
        """
        sad._transition(SupplierSettlementAdjustment.STATUS_DRAFT)
        sad.approved_by = None
        sad.approved_at = None
        sad.approved_by_manager = False
        db.session.flush()

    def _verify_ledger_effect(
        self,
        supplier: Supplier,
        *,
        before: SettlementSnapshot,
        expected_cash_effect: float,
        expected_weight_effect: dict,
        now: datetime,
        context: str,
    ) -> SettlementSnapshot:
        """Law 0, identity 1:  balance_after == balance_before + signed_effect.

        Proving the arithmetic — rather than only that the final balance happens
        to be zero — is what makes the direction rule impossible to invert. A
        posting on the wrong side moves the ledger by +effect instead of
        -effect, so the identity fails even in the cases where a zero-only check
        would have been satisfied by coincidence.

        The same identity is applied per karat, in grams. A karat that was not
        settled carries an expected effect of zero, which is how "a cash
        settlement silently moved gold" gets caught.

        Returns the fresh post-state snapshot so the caller need not re-read.
        """
        after = self.recalculate(supplier, now=now)

        expected_after = round(float(before.financial) + float(expected_cash_effect), 2)
        if abs(after.financial - expected_after) > CASH_EPSILON:
            raise SettlementInvariantViolation(
                f'خرق invariant التسوية [{context}]: الدفتر لم يتحرك بالأثر المقصود. '
                f'قبل={before.financial} + أثر={expected_cash_effect} '
                f'يُتوقع {expected_after}، والفعلي بعد الترحيل {after.financial}. '
                'أُلغيت العملية بالكامل.',
                balance_before=before.financial,
                balance_after=after.financial,
                expected_after=expected_after,
            )

        for key, before_value in before.by_karat.items():
            after_value = float(after.by_karat.get(key, 0.0))
            karat_effect = float((expected_weight_effect or {}).get(key, 0.0))
            expected_karat_after = float(before_value) + karat_effect
            if abs(after_value - expected_karat_after) > WEIGHT_EPSILON:
                raise SettlementInvariantViolation(
                    f'خرق invariant التسوية [{context}]: رصيد العيار {key} لم يتحرك '
                    f'بالأثر المقصود. قبل={before_value} + أثر={karat_effect} '
                    f'يُتوقع {expected_karat_after}، والفعلي {after_value}. '
                    'أُلغيت العملية بالكامل.',
                    balance_before=float(before_value),
                    balance_after=after_value,
                    expected_after=expected_karat_after,
                )

        return after

    def _assert_closed(self, after: SettlementSnapshot, *, context: str) -> None:
        """Law 0, identity 2: a valid settlement leaves nothing open.

        Separate from identity 1 because a reversal satisfies the arithmetic but
        deliberately re-opens the residual — only a settlement must close it.
        """
        if abs(after.financial) > CASH_EPSILON:
            raise SettlementInvariantViolation(
                f'خرق invariant التسوية [{context}]: الرصيد المالي بعد الترحيل '
                f'{after.financial} ولم يصل إلى صفر ضمن دقة {CASH_EPSILON}. '
                'أُلغيت العملية بالكامل.',
                balance_after=after.financial,
                expected_after=0.0,
            )

        still_open = after.open_karats
        if still_open:
            raise SettlementInvariantViolation(
                f'خرق invariant التسوية [{context}]: بقي رصيد وزني بعد الترحيل '
                f'{still_open}. أُلغيت العملية بالكامل.',
            )

    def _resolve_settlement_account_id(self, account_type: str) -> int:
        """Resolve a settlement GL account from configuration. Never guesses."""
        account_id = get_account_id_for_mapping(SETTLEMENT_OPERATION_TYPE, account_type)
        if not account_id or not Account.query.get(int(account_id)):
            raise MissingAccountingMappingError(
                f'لا يوجد حساب محاسبي مربوط لـ {account_type!r} '
                f'ضمن operation_type={SETTLEMENT_OPERATION_TYPE!r}. '
                'أضف صفاً في AccountingMapping قبل الترحيل — '
                'لا يُستخدم حساب افتراضي في التسويات.'
            )
        return int(account_id)

    def _resolve_weight_settlement_account_id(self, account_type: str) -> int:
        """Resolve a weight settlement account and prove it can carry weight.

        A gold line posted to an account that tracks no weight would be silently
        lost, so the mapping is validated against where the canonical resolver
        will actually send the line: either the mapped account tracks weight
        itself, or it is paired to a memo account that does.
        """
        from routes import _resolve_account_id_for_amount_type

        account_id = self._resolve_settlement_account_id(account_type)

        target_id = _resolve_account_id_for_amount_type(account_id, 'gold')
        target = Account.query.get(int(target_id)) if target_id else None
        if not target or not bool(getattr(target, 'tracks_weight', False)):
            raise MissingAccountingMappingError(
                f'الحساب المربوط لـ {account_type!r} لا يصلح لترحيل الوزن: '
                f'سطر الذهب سينتهي إلى الحساب {target_id} وهو لا يتتبع الوزن. '
                'اربط الحساب بحساب مذكرة موازٍ (account pair) أو وجّه الربط '
                'إلى حساب وزني مباشرة.'
            )
        return account_id

    # ── Policy ───────────────────────────────────────────────────────────────

    def _resolve_policy(self, now: datetime) -> SupplierSettlementPolicy | None:
        """Read the policy LIVE at decision time (architecture-v1.md §13)."""
        return SupplierSettlementPolicy.in_effect_at(now)

    @staticmethod
    def _main_karat_equivalent(by_karat: dict) -> float:
        """Total weight expressed in the system's configured Main Karat.

        Karats are converted before being added — never summed as raw grams —
        using the project's canonical converter, which resolves the main karat
        from Settings itself.

        Magnitudes are summed, not signed values: a write-off consumes its
        allowance in either direction, so an offsetting pair of residuals must
        not net down to zero and slip past a limit.
        """
        total = 0.0
        for key, value in (by_karat or {}).items():
            karat = _KARAT_KEYS.get(key)
            if karat is None:
                continue
            grams = abs(float(value or 0.0))
            if not grams:
                continue
            total += abs(float(convert_to_main_karat(grams, karat) or 0.0))
        return round(total, 6)

    @staticmethod
    def _period_key(now: datetime) -> str:
        """Gregorian calendar month key, 'YYYY-MM'.

        Derived from the injected `now`, which by ERP convention is naive
        Riyadh local time — so the month boundary is the business one, not UTC's.
        """
        return now.strftime('%Y-%m')

    def _posted_in_period(
        self,
        supplier: Supplier,
        now: datetime,
        exclude_adjustment_id: int | None,
    ) -> list:
        """Adjustments that consumed allowance this calendar month.

        Reversed originals and reversal documents are both excluded: a posted
        adjustment that was later reversed consumed no net allowance.
        """
        query = (
            SupplierSettlementAdjustment.query
            .filter(SupplierSettlementAdjustment.supplier_id == int(supplier.id))
            .filter(SupplierSettlementAdjustment.period_key == self._period_key(now))
            .filter(SupplierSettlementAdjustment.status == SupplierSettlementAdjustment.STATUS_POSTED)
            .filter(SupplierSettlementAdjustment.reversal_of_id.is_(None))
        )
        if exclude_adjustment_id is not None:
            query = query.filter(SupplierSettlementAdjustment.id != int(exclude_adjustment_id))
        return query.order_by(SupplierSettlementAdjustment.id.asc()).all()

    def _period_consumption(
        self,
        supplier: Supplier,
        now: datetime,
        exclude_adjustment_id: int | None,
    ) -> float:
        """Cash already written off for this supplier in this calendar month."""
        return round(
            sum(
                abs(float(row.posted_amount_cash or 0.0))
                for row in self._posted_in_period(supplier, now, exclude_adjustment_id)
            ),
            CASH_PRECISION,
        )

    def _period_weight_consumption(
        self,
        supplier: Supplier,
        now: datetime,
        exclude_adjustment_id: int | None,
    ) -> float:
        """Weight already written off this month, in Main Karat equivalent.

        Each document's raw per-karat amounts are read back and converted, so
        the cumulative figure is comparable across documents that settled
        different karats. Summed in Python because the raw weights live in a
        JSON column; the row count per supplier per month is tiny by design —
        the caps exist precisely to keep it that way.
        """
        return round(
            sum(
                self._main_karat_equivalent(row.posted_amount_weight_by_karat)
                for row in self._posted_in_period(supplier, now, exclude_adjustment_id)
            ),
            6,
        )

    @staticmethod
    def _review_gate_failure(result: EligibilityResult) -> EligibilityCheck | None:
        """The review-threshold check, if and only if it failed.

        Looked up by name rather than by position, so reordering the check list
        cannot silently change which refusal takes precedence. post() raises on
        it; preview() reports it; both ask this one question.
        """
        by_name = {c.name: c for c in result.checks}
        check = by_name.get(REVIEW_GATE_CHECK)
        return check if (check is not None and not check.passed) else None

    @staticmethod
    def _snapshot_drift(
        sad: SupplierSettlementAdjustment,
        current: SettlementSnapshot,
    ) -> str | None:
        """Describe how the live balance moved away from the stored snapshot.

        Returns None while the snapshot still holds. What a drift *means* is the
        caller's decision — post() kicks the document back to draft and refuses,
        preview() only reports it — but the comparison itself lives here once,
        so both answers come from the same reading and the same epsilons.
        """
        if abs(current.financial - float(sad.balance_before_financial or 0.0)) > CASH_EPSILON:
            return (
                'تغير رصيد المورد منذ إنشاء التسوية. أعد حساب الرصيد ثم أعد الترحيل. '
                f'(اللقطة: {sad.balance_before_financial}، الحالي: {current.financial})'
            )

        stored_weight = sad.balance_before_weight_by_karat
        for key, value in current.by_karat.items():
            if abs(value - float(stored_weight.get(key, 0.0))) > WEIGHT_EPSILON:
                return (
                    'تغير رصيد الوزن للمورد منذ إنشاء التسوية. أعد حساب الرصيد ثم أعد الترحيل. '
                    f'(العيار {key} — اللقطة: {stored_weight.get(key, 0.0)}، الحالي: {value})'
                )
        return None

    def _blocking_reason(
        self,
        result: EligibilityResult,
        drift: str | None,
    ) -> tuple | None:
        """The single refusal a caller should act on, in post()'s own order.

        post() refuses in exactly this sequence: the review gate first (the
        wrong instrument entirely), then a snapshot that no longer holds
        (recalculate, then retry), then the general eligibility verdict. Stating
        the order here once is what keeps preview() and post() from drifting
        into two opinions about which blocker matters.
        """
        review = self._review_gate_failure(result)
        if review is not None:
            return review.name, review.detail

        if drift is not None:
            return REASON_SNAPSHOT_MISMATCH, drift

        failed = result.failed
        if failed:
            return failed[0].name, failed[0].detail
        return None

    def _raise_if_review_required(self, result: EligibilityResult) -> None:
        """Turn the "wrong instrument" verdict into a typed, structured refusal.

        It refuses before anything is written: no workflow starts, no balance
        moves, no residual is reduced. It only names what a human must look at.
        """
        review = self._review_gate_failure(result)
        if review is not None:
            raise SupplierAccountReviewRequiredError(
                review.detail,
                supplier_id=result.supplier_id,
                current_cash_residual=result.snapshot.financial,
                current_weight_residual=result.snapshot.by_karat,
                review_threshold=float(result.policy.review_threshold_cash),
            )

    # ── Eligibility checks ───────────────────────────────────────────────────

    def _check_no_unpaid_invoices(self, supplier: Supplier) -> EligibilityCheck:
        count = (
            Invoice.query
            .filter(Invoice.supplier_id == int(supplier.id))
            .filter(Invoice.status.in_(['unpaid', 'partially_paid']))
            .count()
        )
        return EligibilityCheck(
            name='no_unpaid_invoices',
            passed=count == 0,
            detail='' if count == 0 else f'يوجد {count} فاتورة غير مسددة أو مسددة جزئياً.',
        )

    def _check_no_unposted_journal_entries(self, supplier: Supplier) -> EligibilityCheck:
        count = (
            db.session.query(func.count(func.distinct(JournalEntry.id)))
            .select_from(JournalEntry)
            .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
            .filter(JournalEntryLine.supplier_id == int(supplier.id))
            .filter(func.coalesce(JournalEntry.is_deleted, False) == False)  # noqa: E712
            .filter(func.coalesce(JournalEntryLine.is_deleted, False) == False)  # noqa: E712
            .filter(func.coalesce(JournalEntry.is_posted, False) == False)  # noqa: E712
            .scalar()
        ) or 0
        return EligibilityCheck(
            name='no_unposted_journal_entries',
            passed=count == 0,
            detail='' if count == 0 else f'يوجد {count} قيد غير مرحّل مرتبط بالمورد.',
        )

    def _check_no_pending_vouchers(self, supplier: Supplier) -> EligibilityCheck:
        count = (
            Voucher.query
            .filter(Voucher.supplier_id == int(supplier.id))
            .filter(Voucher.status == 'pending')
            .count()
        )
        return EligibilityCheck(
            name='no_pending_vouchers',
            passed=count == 0,
            detail='' if count == 0 else f'يوجد {count} سند معلّق للمورد.',
        )

    def _check_no_other_open_adjustments(
        self,
        supplier: Supplier,
        exclude_adjustment_id: int | None,
    ) -> EligibilityCheck:
        query = (
            SupplierSettlementAdjustment.query
            .filter(SupplierSettlementAdjustment.supplier_id == int(supplier.id))
            .filter(SupplierSettlementAdjustment.status.in_([
                SupplierSettlementAdjustment.STATUS_DRAFT,
                SupplierSettlementAdjustment.STATUS_APPROVED,
            ]))
        )
        if exclude_adjustment_id is not None:
            query = query.filter(SupplierSettlementAdjustment.id != int(exclude_adjustment_id))
        count = query.count()
        return EligibilityCheck(
            name='no_other_open_adjustments',
            passed=count == 0,
            detail='' if count == 0 else f'يوجد {count} تسوية أخرى مفتوحة لنفس المورد.',
        )

    def _check_has_residual(self, snapshot: SettlementSnapshot) -> EligibilityCheck:
        """Either side may carry the residual — cash, weight, or both."""
        has = snapshot.has_financial_residual or bool(snapshot.open_karats)
        return EligibilityCheck(
            name='has_residual',
            passed=has,
            detail='' if has else 'لا يوجد رصيد متبقٍ (نقدي أو وزني) يستدعي تسوية.',
        )

    def _check_below_review_threshold(
        self,
        snapshot: SettlementSnapshot,
        policy: SupplierSettlementPolicy,
    ) -> EligibilityCheck:
        residual = abs(snapshot.financial)
        threshold = float(policy.review_threshold_cash)
        passed = residual <= threshold
        return EligibilityCheck(
            name='below_review_threshold',
            passed=passed,
            detail='' if passed else (
                f'الرصيد {residual} يتجاوز حد المراجعة {threshold} — '
                'يُحوّل إلى Supplier Account Review ولا يُسجَّل كفرق تسوية.'
            ),
        )

    def _check_within_operation_tolerance(
        self,
        snapshot: SettlementSnapshot,
        policy: SupplierSettlementPolicy,
    ) -> EligibilityCheck:
        """Cash against its limit; total weight, in Main Karat, against its own.

        The weight side is one comparison, not one per karat: the limit governs
        how much gold a single settlement may write off, and that quantity only
        has meaning once the karats are normalized.
        """
        breaches = []

        residual = abs(snapshot.financial)
        if residual > float(policy.tolerance_cash):
            breaches.append(
                f'النقد {residual} يتجاوز حد العملية {float(policy.tolerance_cash)}'
            )

        equivalent = self._main_karat_equivalent(snapshot.open_karats)
        if equivalent > float(policy.tolerance_weight):
            breaches.append(
                f'الوزن المكافئ للعيار الرئيسي {round(equivalent, WEIGHT_PRECISION)} '
                f'يتجاوز حد العملية {float(policy.tolerance_weight)} '
                f'(الخام: {snapshot.open_karats})'
            )

        return EligibilityCheck(
            name='within_operation_tolerance',
            passed=not breaches,
            detail=' · '.join(breaches),
        )

    def _check_within_period_cap(
        self,
        supplier: Supplier,
        snapshot: SettlementSnapshot,
        policy: SupplierSettlementPolicy,
        now: datetime,
        exclude_adjustment_id: int | None,
    ) -> EligibilityCheck:
        period = self._period_key(now)
        breaches = []

        consumed = self._period_consumption(supplier, now, exclude_adjustment_id)
        projected = consumed + abs(snapshot.financial)
        if projected > float(policy.period_cap_cash):
            breaches.append(
                f'النقد: التراكم للفترة {period} سيصبح {round(projected, CASH_PRECISION)} '
                f'ويتجاوز {float(policy.period_cap_cash)} (المستهلك {round(consumed, CASH_PRECISION)})'
            )

        weight_consumed = self._period_weight_consumption(supplier, now, exclude_adjustment_id)
        weight_projected = weight_consumed + self._main_karat_equivalent(snapshot.open_karats)
        if weight_projected > float(policy.period_cap_weight):
            breaches.append(
                f'الوزن (مكافئ العيار الرئيسي): التراكم للفترة {period} سيصبح '
                f'{round(weight_projected, WEIGHT_PRECISION)} ويتجاوز '
                f'{float(policy.period_cap_weight)} '
                f'(المستهلك {round(weight_consumed, WEIGHT_PRECISION)})'
            )

        return EligibilityCheck(
            name='within_period_cap',
            passed=not breaches,
            detail=' · '.join(breaches),
        )

    # ── Numbering ────────────────────────────────────────────────────────────

    @staticmethod
    def _next_adjustment_number(now: datetime) -> str:
        """SAD-YYYY-NNNNN, mirroring generate_voucher_number's collision loop."""
        year = int(now.year)
        pattern = f'SAD-{year}-%'
        last = (
            SupplierSettlementAdjustment.query
            .filter(SupplierSettlementAdjustment.adjustment_number.like(pattern))
            .order_by(SupplierSettlementAdjustment.adjustment_number.desc())
            .first()
        )
        try:
            last_seq = int(str(last.adjustment_number).split('-')[-1]) if last else 0
        except (ValueError, AttributeError):
            last_seq = 0

        next_seq = last_seq + 1
        while True:
            candidate = f'SAD-{year}-{next_seq:05d}'
            exists = (
                SupplierSettlementAdjustment.query
                .filter_by(adjustment_number=candidate)
                .first()
            )
            if not exists:
                return candidate
            next_seq += 1
