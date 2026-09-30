"""
Integration tests for HistoricalClearingAdjustmentService.

Covers the scenario specified by the design review:
  1. Create adjustment → status=pending.
  2. Apply once → exactly one SBT + one JE, correct amounts.
  3. Apply second time → AlreadyAppliedError, no DB changes.
  4. Verify totals: SBT sum == JE sum == adjustment amount.

Run inside the container:
    docker exec yasargold-backend python -m pytest backend/tests/test_historical_clearing_adjustment.py -v
"""

import pytest
from datetime import datetime

from app import app as flask_app
from models import (
    db,
    Account,
    HistoricalClearingAdjustment,
    JournalEntry,
    JournalEntryLine,
    SafeBox,
    SafeBoxTransaction,
)
from historical_clearing_adjustment_service import (
    AlreadyAppliedError,
    HistoricalClearingAdjustmentService,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    """Wrap every test in a savepoint so DB changes don't persist."""

    yield


@pytest.fixture(scope='module')
def test_safe_box(app):
    """Use the real Mada safe box (id=32) — read-only fixture."""
    sb = SafeBox.query.get(32)
    assert sb is not None, 'SafeBox id=32 (مدى) must exist in the DB'
    return sb


@pytest.fixture(scope='module')
def account_ids(app):
    """Return two distinct account IDs for clearing and contra accounts."""
    accounts = Account.query.limit(2).all()
    assert len(accounts) >= 2, 'Need at least 2 accounts in the DB'
    return accounts[0].id, accounts[1].id


# ── Helper ────────────────────────────────────────────────────────────────────

def _create_pending(safe_box_id, amount=6050.00,
                    adjustment_type='historical_allocation_gap'):
    svc = HistoricalClearingAdjustmentService()
    return svc.create(
        safe_box_id=safe_box_id,
        amount=amount,
        adjustment_type=adjustment_type,
        reason=f'Integration test — {adjustment_type}',
        created_by='test',
    )


# ── Test cases ────────────────────────────────────────────────────────────────

class TestCreate:
    def test_status_is_pending(self, test_safe_box):
        adj = _create_pending(test_safe_box.id)
        assert adj.id is not None
        assert adj.status == 'pending'
        assert adj.safe_box_transaction_id is None
        assert adj.journal_entry_id is None

    def test_invalid_type_raises(self, test_safe_box):
        svc = HistoricalClearingAdjustmentService()
        with pytest.raises(ValueError, match='Invalid adjustment_type'):
            svc.create(
                safe_box_id=test_safe_box.id,
                amount=100.0,
                adjustment_type='invalid_type',
                reason='test',
                created_by='test',
            )

    def test_negative_amount_raises(self, test_safe_box):
        svc = HistoricalClearingAdjustmentService()
        with pytest.raises(ValueError, match='positive'):
            svc.create(
                safe_box_id=test_safe_box.id,
                amount=-500.0,
                adjustment_type='historical_allocation_gap',
                reason='test',
                created_by='test',
            )

    def test_nonexistent_safe_box_raises(self):
        svc = HistoricalClearingAdjustmentService()
        with pytest.raises(ValueError, match='SafeBox'):
            svc.create(
                safe_box_id=999999,
                amount=100.0,
                adjustment_type='historical_allocation_gap',
                reason='test',
                created_by='test',
            )


class TestApply:
    # ── allocation_gap: creates SBT + JE ─────────────────────────────────────

    def test_allocation_gap_creates_sbt(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id, adjustment_type='historical_allocation_gap')
        svc = HistoricalClearingAdjustmentService()
        svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )
        sbts = SafeBoxTransaction.query.filter_by(
            ref_type='historical_clearing_adjustment', ref_id=adj.id,
        ).all()
        assert len(sbts) == 1
        assert sbts[0].direction == 'in'
        assert abs(sbts[0].amount_cash - 6050.0) < 0.01

    def test_allocation_gap_links_sbt_to_adjustment(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id, adjustment_type='historical_allocation_gap')
        svc = HistoricalClearingAdjustmentService()
        svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )
        assert adj.safe_box_transaction_id is not None
        sbt = SafeBoxTransaction.query.get(adj.safe_box_transaction_id)
        assert sbt is not None and sbt.ref_id == adj.id

    # ── gl_adjustment: creates JE only, no SBT ───────────────────────────────

    def test_gl_adjustment_skips_sbt(self, test_safe_box, account_ids):
        """historical_gl_adjustment is GL-only — no physical cash gap → no SBT."""
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id, adjustment_type='historical_gl_adjustment')
        svc = HistoricalClearingAdjustmentService()
        svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )
        assert adj.safe_box_transaction_id is None, \
            'historical_gl_adjustment must not create a SafeBoxTransaction'

        sbts = SafeBoxTransaction.query.filter_by(
            ref_type='historical_clearing_adjustment', ref_id=adj.id,
        ).all()
        assert len(sbts) == 0

    def test_gl_adjustment_still_creates_je(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id, adjustment_type='historical_gl_adjustment')
        svc = HistoricalClearingAdjustmentService()
        svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )
        assert adj.journal_entry_id is not None
        lines = JournalEntryLine.query.filter_by(journal_entry_id=adj.journal_entry_id).all()
        assert len(lines) == 2
        assert abs(sum(l.cash_debit for l in lines) - 6050.0) < 0.01
        assert abs(sum(l.cash_credit for l in lines) - 6050.0) < 0.01

    # ── common: JE always created, status always applied ─────────────────────

    def test_apply_creates_exactly_one_je(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()
        svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )
        jes = JournalEntry.query.filter_by(
            reference_type='historical_clearing_adjustment',
            reference_id=adj.id,
        ).all()
        assert len(jes) == 1
        lines = JournalEntryLine.query.filter_by(journal_entry_id=jes[0].id).all()
        assert len(lines) == 2
        assert abs(sum(l.cash_debit for l in lines) - 6050.0) < 0.01
        assert abs(sum(l.cash_credit for l in lines) - 6050.0) < 0.01

    def test_apply_sets_status_applied(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()
        result = svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )
        assert result.status == 'applied'
        assert result.journal_entry_id is not None
        assert result.approved_by == 'test'
        assert result.approved_at is not None


class TestIdempotency:
    def test_second_apply_raises_already_applied_error(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()

        # First apply — should succeed
        svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )

        # Second apply — must raise AlreadyAppliedError
        with pytest.raises(AlreadyAppliedError):
            svc.apply(
                adjustment_id=adj.id,
                applied_by='test',
                clearing_account_id=clearing_acc,
                contra_account_id=contra_acc,
            )

    def test_second_apply_leaves_db_unchanged(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()

        svc.apply(
            adjustment_id=adj.id,
            applied_by='test',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )

        sbt_count_before = SafeBoxTransaction.query.filter_by(
            ref_type='historical_clearing_adjustment', ref_id=adj.id
        ).count()
        je_count_before = JournalEntry.query.filter_by(
            reference_type='historical_clearing_adjustment', reference_id=adj.id
        ).count()

        try:
            svc.apply(
                adjustment_id=adj.id,
                applied_by='test',
                clearing_account_id=clearing_acc,
                contra_account_id=contra_acc,
            )
        except AlreadyAppliedError:
            pass

        # Counts must not change after the failed second apply
        assert SafeBoxTransaction.query.filter_by(
            ref_type='historical_clearing_adjustment', ref_id=adj.id
        ).count() == sbt_count_before

        assert JournalEntry.query.filter_by(
            reference_type='historical_clearing_adjustment', reference_id=adj.id
        ).count() == je_count_before


class TestValidation:
    def test_same_accounts_raises(self, test_safe_box, account_ids):
        clearing_acc, _ = account_ids
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()

        with pytest.raises(ValueError, match='different accounts'):
            svc.apply(
                adjustment_id=adj.id,
                applied_by='test',
                clearing_account_id=clearing_acc,
                contra_account_id=clearing_acc,  # same!
            )

    def test_nonexistent_account_raises(self, test_safe_box):
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()

        with pytest.raises(ValueError, match='does not exist'):
            svc.apply(
                adjustment_id=adj.id,
                applied_by='test',
                clearing_account_id=999999,
                contra_account_id=999998,
            )

    def test_cancel_then_apply_raises(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()

        svc.cancel(adjustment_id=adj.id, cancelled_by='test', reason='test cancel')

        with pytest.raises(ValueError):
            svc.apply(
                adjustment_id=adj.id,
                applied_by='test',
                clearing_account_id=clearing_acc,
                contra_account_id=contra_acc,
            )


class TestAuditTrail:
    def test_to_dict_contains_all_audit_fields(self, test_safe_box, account_ids):
        clearing_acc, contra_acc = account_ids
        adj = _create_pending(test_safe_box.id)
        svc = HistoricalClearingAdjustmentService()

        svc.apply(
            adjustment_id=adj.id,
            applied_by='auditor',
            clearing_account_id=clearing_acc,
            contra_account_id=contra_acc,
        )

        d = adj.to_dict()
        required_audit_keys = {
            'id', 'safe_box_id', 'amount', 'adjustment_type',
            'reference_voucher_id', 'reference_voucher_number',
            'reason',
            'created_by', 'created_at',
            'approved_by', 'approved_at',
            'status',
            'safe_box_transaction_id', 'journal_entry_id',
        }
        missing = required_audit_keys - d.keys()
        assert not missing, f'Missing audit keys in to_dict(): {missing}'

        assert d['status'] == 'applied'
        assert d['approved_by'] == 'auditor'
        assert d['safe_box_transaction_id'] is not None
        assert d['journal_entry_id'] is not None
