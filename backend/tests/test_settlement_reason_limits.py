"""A settlement limit belongs to the DECISION, not to the mechanism.

One `tolerance_cash` governed every reason alike, so a documented supplier waiver
— a deliberate business act of any size — was refused by a rounding limit of
5 SAR. That single number is why most real residuals could not be settled at all
and why the refusal looked arbitrary.

Both dimensions matter throughout: cash in riyals and gold as MAIN-KARAT-
EQUIVALENT weight, which is the only unit in which karats can be compared.

The load-bearing pair is TestRoundingStaysProtected alongside
TestWaiverCanExceedTheRoundingLimit: raising the waiver ceiling must not raise the
rounding one, or the guard is gone rather than targeted.

Run:
    python -m pytest tests/test_settlement_reason_limits.py -v
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import (
    SupplierSettlementAdjustment as SAD,
    SupplierSettlementPolicy,
    SupplierSettlementReasonLimit,
    db,
)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app):
    connection = db.engine.connect()
    transaction = connection.begin()
    db.session.bind = connection
    nested = connection.begin_nested()
    yield
    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


def _policy(**overrides):
    values = dict(
        tolerance_cash=5.0, tolerance_weight=0.05,
        period_cap_cash=50.0, period_cap_weight=0.5,
        review_threshold_cash=500.0,
        effective_from=datetime.now() - timedelta(days=1),
        created_by='test',
    )
    values.update(overrides)
    p = SupplierSettlementPolicy(**values)
    db.session.add(p)
    db.session.flush()
    return p


def _limit(policy, reason_code, *, cash, weight, manager=False,
           review_threshold=None, cap_cash=None, cap_weight=None):
    row = SupplierSettlementReasonLimit(
        policy_id=policy.id, reason_code=reason_code,
        tolerance_cash=cash, tolerance_weight_main_karat=weight,
        review_threshold_cash=review_threshold,
        period_cap_cash=cap_cash,
        period_cap_weight_main_karat=cap_weight,
        requires_manager_approval=manager,
    )
    db.session.add(row)
    db.session.flush()
    return row


class TestFallbackKeepsOldBehaviour:

    def test_a_reason_with_no_row_uses_the_global_limits(self):
        """Adding the table changed nothing on its own — every reason keeps the
        ceiling it had until finance sets a different one."""
        policy = _policy()
        limits = policy.limits_for_reason(SAD.REASON_ROUNDING_DIFFERENCE)
        assert limits.tolerance_cash == 5.0
        assert limits.tolerance_weight == 0.05
        assert limits.is_explicit is False
        assert limits.requires_manager_approval is None, 'no opinion of its own; the hard-coded set still decides'

    def test_both_dimensions_come_back(self):
        policy = _policy(tolerance_cash=9.0, tolerance_weight=0.09)
        limits = policy.limits_for_reason(SAD.REASON_OTHER)
        assert (limits.tolerance_cash, limits.tolerance_weight) == (9.0, 0.09)


class TestWaiverCanExceedTheRoundingLimit:

    def test_a_waiver_gets_its_own_cash_ceiling(self):
        """The case that was impossible: 20,349 SAR waived deliberately."""
        policy = _policy(tolerance_cash=5.0)
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True)

        limits = policy.limits_for_reason(SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER)
        assert limits.tolerance_cash == 25000.0
        assert limits.tolerance_weight == 50.0
        assert limits.requires_manager_approval is True

    def test_a_waiver_gets_its_own_gold_ceiling_in_main_karat(self):
        policy = _policy(tolerance_weight=0.05)
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, cash=0.0, weight=120.0)
        limits = policy.limits_for_reason(SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER)
        assert limits.tolerance_weight == 120.0, 'gold is settled too, and in main-karat-equivalent'


class TestRoundingStaysProtected:

    def test_raising_the_waiver_ceiling_does_not_raise_rounding(self):
        """The whole point of per-reason limits: the guard is targeted, not
        removed. A 25,000 waiver allowance must leave rounding at 5."""
        policy = _policy(tolerance_cash=5.0, tolerance_weight=0.05)
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True)

        limits = policy.limits_for_reason(SAD.REASON_ROUNDING_DIFFERENCE)
        assert limits.tolerance_cash == 5.0
        assert limits.tolerance_weight == 0.05

    def test_rounding_can_be_tightened_independently(self):
        policy = _policy(tolerance_cash=5.0)
        _limit(policy, SAD.REASON_ROUNDING_DIFFERENCE, cash=1.0, weight=0.01)
        limits = policy.limits_for_reason(SAD.REASON_ROUNDING_DIFFERENCE)
        assert (limits.tolerance_cash, limits.tolerance_weight) == (1.0, 0.01)


class TestOneRowPerReasonPerPolicy:

    def test_the_same_reason_cannot_be_defined_twice(self):
        from sqlalchemy.exc import IntegrityError
        policy = _policy()
        _limit(policy, SAD.REASON_WEIGHT_DIFFERENCE, cash=0.0, weight=1.0)
        db.session.add(SupplierSettlementReasonLimit(
            policy_id=policy.id, reason_code=SAD.REASON_WEIGHT_DIFFERENCE,
            tolerance_cash=0.0, tolerance_weight_main_karat=2.0,
        ))
        with pytest.raises(IntegrityError):
            db.session.flush()

    def test_limits_belong_to_one_policy_only(self):
        """Effective dating lives on the parent, so correcting a limit closes the
        policy and inserts a new one — history is never edited in place."""
        old = _policy()
        _limit(old, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, cash=1000.0, weight=1.0)
        new = _policy(effective_from=datetime.now())
        _limit(new, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, cash=25000.0, weight=50.0)

        assert old.limits_for_reason(
            SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER).tolerance_cash == 1000.0
        assert new.limits_for_reason(
            SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER).tolerance_cash == 25000.0


class TestManagerAuthorityFollowsTheCeiling:

    def test_a_reason_can_be_made_manager_only_by_policy(self):
        from services.supplier_settlement_adjustment_service import (
            SupplierSettlementAdjustmentService,
        )
        policy = _policy(effective_from=datetime.now() - timedelta(hours=1))
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True)

        svc = SupplierSettlementAdjustmentService()
        assert svc._requires_manager(
            SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, now=datetime.now()
        ) is True

    def test_other_always_requires_a_manager_regardless_of_policy(self):
        """The hard-coded set is a floor policy cannot lower."""
        from services.supplier_settlement_adjustment_service import (
            SupplierSettlementAdjustmentService,
        )
        policy = _policy(effective_from=datetime.now() - timedelta(hours=1))
        _limit(policy, SAD.REASON_OTHER, cash=1.0, weight=0.01, manager=False)

        svc = SupplierSettlementAdjustmentService()
        assert svc._requires_manager(SAD.REASON_OTHER, now=datetime.now()) is True


# ======================================================================
# THE LOAD-BEARING WITNESS — the real case, through the real service
#
# Everything above tests the lookup. This tests the DECISION, and it is the
# only thing that proves the user can now settle what they could not settle
# before. Three independent gates stand between a residual and a settlement:
#
#     below_review_threshold      review_threshold_cash    (500)
#     within_operation_tolerance  tolerance_cash/weight    (5 / 0.05)
#     within_period_cap           period_cap_cash/weight   (50 / 0.5)
#
# Raising only the middle one leaves the other two refusing. A feature that
# stops at the lookup would look finished and change nothing in the screen.
# ======================================================================

from models import JournalEntry, JournalEntryLine, Supplier
from party_account_service import ensure_supplier_accounts
from services.party_live_balances import compute_live_supplier_balances
from services.supplier_settlement_adjustment_service import (
    SupplierSettlementAdjustmentService,
)

NOW = datetime(2026, 9, 25, 10, 0, 0)


def _supplier(code_suffix='RL1'):
    s = Supplier(supplier_code=f'S-SRL-{code_suffix}', name=f'مورد حدود {code_suffix}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


def _give_residual(supplier, *, cash=0.0, karat_field=None, karat_amount=0.0):
    accounts = ensure_supplier_accounts(supplier)
    je = JournalEntry(
        entry_number=f'JE-SRL-{supplier.id}-{datetime.now().timestamp()}',
        date=NOW - timedelta(days=1), description='رصيد اختباري',
        entry_type='عادي', is_posted=True, is_draft=False, created_by='test',
    )
    db.session.add(je)
    db.session.flush()
    kwargs = {'journal_entry_id': je.id, 'account_id': accounts.financial.id,
              'supplier_id': supplier.id, 'description': 'رصيد اختباري'}
    if cash:
        kwargs['cash_debit' if cash > 0 else 'cash_credit'] = abs(cash)
    if karat_field:
        kwargs[karat_field] = karat_amount
    db.session.add(JournalEntryLine(**kwargs))
    db.session.flush()


def _refusals(supplier, policy, reason_code):
    """Which gates refuse this settlement, by name."""
    result = SupplierSettlementAdjustmentService().check_eligibility(
        supplier, now=NOW, policy=policy, reason_code=reason_code,
    )
    return {c.name for c in result.checks if not c.passed}


class TestADocumentedWaiverCanActuallyBeSettled:

    def test_a_large_cash_waiver_passes_every_gate_once_its_limits_are_set(self):
        """The case from the screen: 20,349.37 SAR left on a supplier, waived
        with a document. Finance sets the waiver's ceilings; nothing else moves."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True,
               review_threshold=25000.0, cap_cash=25000.0, cap_weight=50.0)
        supplier = _supplier('WAIVE-C')
        _give_residual(supplier, cash=20349.37)

        assert _refusals(supplier, policy,
                         SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER) == set(), (
            'a waiver inside its own ceiling must clear the review threshold and '
            'the period cap too — those still measure it against rounding numbers'
        )

    def test_a_large_gold_waiver_passes_every_gate_once_its_limits_are_set(self):
        """Gold is settled in the same act and must clear the same three gates,
        measured in main-karat-equivalent."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True,
               review_threshold=25000.0, cap_cash=25000.0, cap_weight=50.0)
        supplier = _supplier('WAIVE-G')
        _give_residual(supplier, karat_field='debit_21k', karat_amount=12.500)

        assert _refusals(supplier, policy,
                         SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER) == set()


class TestTheGuardIsTargetedNotRemoved:

    def test_the_same_amount_as_a_rounding_difference_is_still_refused(self):
        """20,349 SAR is not a rounding error. Every gate that refused it before
        must refuse it still — the waiver's ceiling is the waiver's alone."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True,
               review_threshold=25000.0, cap_cash=25000.0, cap_weight=50.0)
        supplier = _supplier('ROUND-C')
        _give_residual(supplier, cash=20349.37)

        refused = _refusals(supplier, policy, SAD.REASON_ROUNDING_DIFFERENCE)
        assert 'within_operation_tolerance' in refused
        assert 'below_review_threshold' in refused
        assert 'within_period_cap' in refused

    def test_the_same_weight_as_a_rounding_difference_is_still_refused(self):
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True,
               review_threshold=25000.0, cap_cash=25000.0, cap_weight=50.0)
        supplier = _supplier('ROUND-G')
        _give_residual(supplier, karat_field='debit_21k', karat_amount=12.500)

        refused = _refusals(supplier, policy, SAD.REASON_ROUNDING_DIFFERENCE)
        assert 'within_operation_tolerance' in refused
        assert 'within_period_cap' in refused

    def test_a_waiver_beyond_its_own_ceiling_is_refused(self):
        """The ceiling is a real limit, not a bypass."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, cash=1000.0, weight=1.0)
        supplier = _supplier('WAIVE-OVER')
        _give_residual(supplier, cash=20349.37)

        assert 'within_operation_tolerance' in _refusals(
            supplier, policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER
        )


# ======================================================================
# A cap is meaningless without saying what counts against it
# ======================================================================

class TestBudgetsCountOnlyWhatDrawsOnThem:

    def test_with_no_per_reason_cap_every_reason_shares_one_budget(self):
        """None means "count everything" — the original behaviour, preserved
        exactly while finance has set no per-reason cap."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0)  # tolerance only, no cap

        assert policy.period_budget_scope(
            SAD.REASON_ROUNDING_DIFFERENCE, dimension='cash') is None
        assert policy.period_budget_scope(
            SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, dimension='cash') is None

    def test_a_reason_with_its_own_cap_is_its_own_budget(self):
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, cap_cash=25000.0)

        assert policy.period_budget_scope(
            SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, dimension='cash'
        ) == frozenset({SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER})

    def test_reasons_without_their_own_cap_still_count_each_other(self):
        """And they no longer count the waiver — otherwise a single 20,000 waiver
        would exhaust the 50 SAR rounding allowance for the rest of the month and
        the per-reason cap would create a new blockage while relieving the old."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, cap_cash=25000.0)

        shared = policy.period_budget_scope(
            SAD.REASON_ROUNDING_DIFFERENCE, dimension='cash')
        assert SAD.REASON_ROUNDING_DIFFERENCE in shared
        assert SAD.REASON_WEIGHT_DIFFERENCE in shared
        assert SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER not in shared

    def test_the_two_dimensions_are_scoped_independently(self):
        """A reason may own its cash budget and share the gold one."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, cap_cash=25000.0)  # no weight cap

        assert policy.period_budget_scope(
            SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, dimension='cash'
        ) == frozenset({SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER})
        assert policy.period_budget_scope(
            SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, dimension='weight') is None


def _posted_settlement(supplier, reason_code, *, cash, now=NOW):
    """The shape post() leaves behind — only the fields consumption reads."""
    sad = SAD(
        adjustment_number=f'SAD-TEST-{uuid.uuid4().hex[:10]}',
        supplier_id=int(supplier.id), reason_code=reason_code,
        status=SAD.STATUS_POSTED,
        period_key=f'{now.year}-{now.month:02d}',
        posted_amount_cash=cash, created_by='test',
    )
    db.session.add(sad)
    db.session.flush()
    return sad


class TestOneLargeWaiverDoesNotBlockTheMonth:

    def test_a_posted_waiver_leaves_the_rounding_allowance_intact(self):
        """The trap this design avoids, proven end to end through the gates."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True,
               review_threshold=25000.0, cap_cash=25000.0, cap_weight=50.0)
        supplier = _supplier('MONTH')
        _posted_settlement(supplier, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, cash=20349.37)

        # A 3 SAR rounding difference afterwards, well inside its own limits.
        _give_residual(supplier, cash=3.00)

        assert _refusals(supplier, policy, SAD.REASON_ROUNDING_DIFFERENCE) == set(), (
            "a waiver drawing on its own budget must not consume the rounding "
            "allowance — otherwise raising one ceiling blocks every other reason"
        )

    def test_a_second_waiver_beyond_the_shared_month_is_still_capped(self):
        """Its own budget is still a budget."""
        policy = _policy()
        _limit(policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
               cash=25000.0, weight=50.0, manager=True,
               review_threshold=25000.0, cap_cash=25000.0, cap_weight=50.0)
        supplier = _supplier('MONTH2')
        _posted_settlement(supplier, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER, cash=20000.0)
        _give_residual(supplier, cash=6000.00)

        assert 'within_period_cap' in _refusals(
            supplier, policy, SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER
        ), '20,000 + 6,000 exceeds the waiver cap of 25,000'
