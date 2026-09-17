"""Integration tests for SupplierSettlementAdjustmentService.

The load-bearing test here is test_invariant_catches_inverted_direction: it
proves the closing invariant actually fires when the entry is posted on the
wrong side. Without that RED witness, the invariant is a comment.

Run:
    python -m pytest tests/test_supplier_settlement_adjustment.py -v
"""

import pytest
from datetime import datetime, timedelta

from app import app as flask_app
from models import (
    Account,
    AccountingMapping,
    JournalEntry,
    JournalEntryLine,
    Supplier,
    SupplierSettlementAdjustment,
    SupplierSettlementPolicy,
    Voucher,
    db,
)
from account_pair_service import link_accounts
from party_account_service import ensure_supplier_accounts
from services.party_live_balances import compute_live_supplier_balances
from services.supplier_settlement_adjustment_service import (
    ACCOUNT_TYPE_SETTLEMENT_EXPENSE,
    ACCOUNT_TYPE_SETTLEMENT_INCOME,
    ACCOUNT_TYPE_WEIGHT_SETTLEMENT_EXPENSE,
    ACCOUNT_TYPE_WEIGHT_SETTLEMENT_INCOME,
    SETTLEMENT_OPERATION_TYPE,
    ManagerApprovalRequiredError,
    MissingAccountingMappingError,
    NotEligibleError,
    SettlementInvariantViolation,
    SnapshotMismatchError,
    SupplierAccountReviewRequiredError,
    SupplierSettlementAdjustmentService,
)


NOW = datetime(2026, 9, 16, 10, 0, 0)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app):
    """Wrap every test in a savepoint so DB changes don't persist."""
    connection = db.engine.connect()
    transaction = connection.begin()
    db.session.bind = connection
    nested = connection.begin_nested()

    yield

    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


@pytest.fixture
def policy():
    p = SupplierSettlementPolicy(
        tolerance_cash=5.00,
        tolerance_weight=0.050,
        period_cap_cash=50.00,
        period_cap_weight=0.500,
        review_threshold_cash=500.00,
        effective_from=NOW - timedelta(days=30),
        created_by='test',
    )
    db.session.add(p)
    db.session.flush()
    return p


@pytest.fixture
def settlement_accounts():
    """The four GL accounts + their AccountingMapping rows.

    The weight settlement accounts are ordinary financial accounts paired to
    memo accounts through link_accounts() — the same account-pair infrastructure
    production uses. Nothing here derives a memo account number by prefix.
    """
    expense = Account(
        account_number='5901', name='مصروف فروقات تسوية موردين',
        type='Expense', tracks_weight=False,
    )
    income = Account(
        account_number='4901', name='إيراد فروقات تسوية موردين',
        type='Revenue', tracks_weight=False,
    )
    weight_expense = Account(
        account_number='5902', name='مصروف فروقات تسوية وزن موردين',
        type='Expense', tracks_weight=False,
    )
    weight_income = Account(
        account_number='4902', name='إيراد فروقات تسوية وزن موردين',
        type='Revenue', tracks_weight=False,
    )
    weight_expense_memo = Account(
        account_number='75902', name='مذكرة مصروف فروقات تسوية وزن',
        type='Expense', tracks_weight=True,
    )
    weight_income_memo = Account(
        account_number='74902', name='مذكرة إيراد فروقات تسوية وزن',
        type='Revenue', tracks_weight=True,
    )
    db.session.add_all([
        expense, income, weight_expense, weight_income,
        weight_expense_memo, weight_income_memo,
    ])
    db.session.flush()

    link_accounts(weight_expense, weight_expense_memo, created_by='test')
    link_accounts(weight_income, weight_income_memo, created_by='test')
    db.session.flush()

    db.session.add_all([
        AccountingMapping(
            operation_type=SETTLEMENT_OPERATION_TYPE,
            account_type=ACCOUNT_TYPE_SETTLEMENT_EXPENSE,
            account_id=expense.id,
            is_active=True,
        ),
        AccountingMapping(
            operation_type=SETTLEMENT_OPERATION_TYPE,
            account_type=ACCOUNT_TYPE_SETTLEMENT_INCOME,
            account_id=income.id,
            is_active=True,
        ),
        AccountingMapping(
            operation_type=SETTLEMENT_OPERATION_TYPE,
            account_type=ACCOUNT_TYPE_WEIGHT_SETTLEMENT_EXPENSE,
            account_id=weight_expense.id,
            is_active=True,
        ),
        AccountingMapping(
            operation_type=SETTLEMENT_OPERATION_TYPE,
            account_type=ACCOUNT_TYPE_WEIGHT_SETTLEMENT_INCOME,
            account_id=weight_income.id,
            is_active=True,
        ),
    ])
    db.session.flush()
    return {
        'expense': expense,
        'income': income,
        'weight_expense': weight_expense,
        'weight_income': weight_income,
        'weight_expense_memo': weight_expense_memo,
        'weight_income_memo': weight_income_memo,
    }


@pytest.fixture
def supplier():
    s = Supplier(supplier_code='S-SAD-001', name='مورد اختبار التسوية')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


@pytest.fixture
def service():
    return SupplierSettlementAdjustmentService()


def _give_residual(supplier, *, cash=0.0, karat_field=None, karat_amount=0.0, debit=True):
    """Seed ledger state so the supplier carries a residual.

    Positive cash (debit) means the supplier owes us, exactly as
    compute_live_supplier_balances reports it.
    """
    accounts = ensure_supplier_accounts(supplier)
    je = JournalEntry(
        entry_number=f'JE-TEST-{supplier.id}-{datetime.now().timestamp()}',
        date=NOW - timedelta(days=1),
        description='رصيد اختباري',
        entry_type='عادي',
        is_posted=True,
        is_draft=False,
        created_by='test',
    )
    db.session.add(je)
    db.session.flush()

    line_kwargs = {
        'journal_entry_id': je.id,
        'account_id': accounts.financial.id,
        'supplier_id': supplier.id,
        'description': 'رصيد اختباري',
    }
    if cash:
        line_kwargs['cash_debit' if cash > 0 else 'cash_credit'] = abs(cash)
    if karat_field:
        line_kwargs[karat_field] = karat_amount

    db.session.add(JournalEntryLine(**line_kwargs))
    db.session.flush()
    return je


def _balance(supplier):
    return compute_live_supplier_balances([supplier]).get(int(supplier.id)) or {}


def _post_adjustment(service, supplier, *, reason=None, note=None, is_manager=False):
    reason = reason or SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE
    sad = service.create_draft(
        supplier=supplier, reason_code=reason, created_by='tester', now=NOW, note=note,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW, is_manager=is_manager)
    return service.post(sad=sad, posted_by='poster', now=NOW)


# ── The invariant ─────────────────────────────────────────────────────────────

def test_post_closes_balance_when_supplier_owes_us(service, supplier, policy, settlement_accounts):
    """residual > 0 → Cr supplier / Dr settlement expense → balance zero."""
    _give_residual(supplier, cash=3.00)
    assert round(_balance(supplier)['cash'], 2) == 3.00

    sad = _post_adjustment(service, supplier)

    assert sad.status == SupplierSettlementAdjustment.STATUS_POSTED
    assert round(_balance(supplier)['cash'], 2) == 0.00

    lines = sad.voucher.account_lines.all()
    supplier_account_id = ensure_supplier_accounts(supplier).financial.id
    supplier_line = next(l for l in lines if l.account_id == supplier_account_id)
    counter_line = next(l for l in lines if l.account_id == settlement_accounts['expense'].id)
    assert supplier_line.line_type == 'credit'
    assert counter_line.line_type == 'debit'


def test_post_closes_balance_when_we_owe_supplier(service, supplier, policy, settlement_accounts):
    """residual < 0 → Dr supplier / Cr settlement income → balance zero."""
    _give_residual(supplier, cash=-2.50)
    assert round(_balance(supplier)['cash'], 2) == -2.50

    sad = _post_adjustment(service, supplier)

    assert round(_balance(supplier)['cash'], 2) == 0.00

    lines = sad.voucher.account_lines.all()
    supplier_account_id = ensure_supplier_accounts(supplier).financial.id
    supplier_line = next(l for l in lines if l.account_id == supplier_account_id)
    counter_line = next(l for l in lines if l.account_id == settlement_accounts['income'].id)
    assert supplier_line.line_type == 'debit'
    assert counter_line.line_type == 'credit'


def test_invariant_catches_inverted_direction(service, supplier, policy, settlement_accounts):
    """RED witness: post on the wrong side and prove the invariant fires.

    This is the test that makes the direction rule binding. If someone later
    'fixes' the sign convention backwards, the residual grows instead of
    closing and this mechanism rejects the whole transaction.
    """
    _give_residual(supplier, cash=3.00)

    original_builder = service._build_and_post_voucher

    def inverted(*args, **kwargs):
        kwargs['residual_cash'] = -kwargs['residual_cash']
        kwargs['residual_by_karat'] = {
            k: -v for k, v in (kwargs['residual_by_karat'] or {}).items()
        }
        return original_builder(*args, **kwargs)

    service._build_and_post_voucher = inverted

    with pytest.raises(SettlementInvariantViolation) as exc:
        _post_adjustment(service, supplier)

    err = exc.value
    # Proven numerically, not by string matching: the wrong direction moved the
    # ledger away from zero instead of towards it.
    assert err.expected_after == 0.0
    assert abs(err.balance_after) > abs(err.balance_before)
    assert round(err.balance_after, 2) == 6.00


def test_law0_arithmetic_identity_holds_for_cash_and_every_karat(
    service, supplier, policy, settlement_accounts
):
    """balance_after == balance_before + signed_effect, and after == 0.

    Checking only that the final balance is zero would pass by coincidence in
    cases where the ledger never moved at all. The identity proves the
    settlement's own effect was exactly -residual, and that it touched no karat.
    """
    _give_residual(supplier, cash=3.00)

    before = _balance(supplier)
    signed_effect = -before['cash']

    sad = _post_adjustment(service, supplier)
    after = _balance(supplier)

    # Identity 1 — the ledger moved by exactly the intended effect.
    assert round(after['cash'], 2) == round(before['cash'] + signed_effect, 2)
    # Identity 2 — and that effect closed the account.
    assert round(after['cash'], 2) == 0.00
    # The effect recorded on the document is the residual it closed.
    assert round(sad.posted_amount_cash, 2) == 3.00

    # A cash settlement posts no weight: every karat must be untouched and zero.
    for karat in ('18k', '21k', '22k', '24k'):
        assert round(after[karat], 3) == round(before[karat] + 0.0, 3)
        assert round(after[karat], 3) == 0.000


def test_invariant_catches_inverted_weight_direction(
    service, supplier, policy, settlement_accounts
):
    """RED witness on the weight side specifically.

    Cash could be correct while the weight side is posted backwards, so the
    karat identity needs its own proof that it fires.
    """
    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)

    original_builder = service._build_and_post_voucher

    def inverted_weight_only(*args, **kwargs):
        kwargs['residual_by_karat'] = {
            k: -v for k, v in (kwargs['residual_by_karat'] or {}).items()
        }
        return original_builder(*args, **kwargs)

    service._build_and_post_voucher = inverted_weight_only

    with pytest.raises(SettlementInvariantViolation) as exc:
        _post_adjustment(
            service, supplier,
            reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
        )

    err = exc.value
    assert err.expected_after == 0.0
    assert abs(err.balance_after) > abs(err.balance_before)
    assert round(err.balance_after, 3) == 0.060


def test_law0_identity_holds_for_weight_on_every_settled_karat(
    service, supplier, policy, settlement_accounts
):
    """after == before + signed_effect, in grams, per karat."""
    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)
    _give_residual(supplier, karat_field='credit_18k', karat_amount=0.020)

    before = _balance(supplier)
    effects = {'21k': -before['21k'], '18k': -before['18k']}

    sad = _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )
    after = _balance(supplier)

    for karat, effect in effects.items():
        assert round(after[karat], 3) == round(before[karat] + effect, 3)
        assert round(after[karat], 3) == 0.000

    # Untouched karats stayed untouched.
    for karat in ('22k', '24k'):
        assert round(after[karat], 3) == round(before[karat], 3)

    assert round(sad.posted_amount_weight_by_karat['21k'], 3) == 0.030
    assert round(sad.posted_amount_weight_by_karat['18k'], 3) == -0.020


def test_reversal_restores_cash_and_weight_together(
    service, supplier, policy, settlement_accounts
):
    """A reversal mirrors both sides and re-opens the original residual."""
    _give_residual(supplier, cash=3.00, karat_field='debit_21k', karat_amount=0.030)
    sad = _post_adjustment(service, supplier)

    assert round(_balance(supplier)['cash'], 2) == 0.00
    assert round(_balance(supplier)['21k'], 3) == 0.000

    reversal = service.reverse(sad=sad, reversed_by='r', reason='عكس', now=NOW)

    balance = _balance(supplier)
    # Explicitly NOT zero — the reversal re-opens what the settlement closed.
    assert round(balance['cash'], 2) == 3.00
    assert round(balance['21k'], 3) == 0.030

    assert round(reversal.posted_amount_cash, 2) == -3.00
    assert round(reversal.posted_amount_weight_by_karat['21k'], 3) == -0.030
    assert sad.status == SupplierSettlementAdjustment.STATUS_REVERSED


def test_karats_are_never_summed_as_raw_grams(service):
    """0.010g of 18k + 0.030g of 21k + 0.020g of 24k is not 0.060g of anything."""
    raw = {'18k': 0.010, '21k': 0.030, '24k': 0.020}

    equivalent = service._main_karat_equivalent(raw)

    naive_sum = 0.060
    assert equivalent != pytest.approx(naive_sum)
    # 0.010*18/21 + 0.030 + 0.020*24/21, main karat = 21
    assert equivalent == pytest.approx(0.0614286, abs=1e-6)


def test_main_karat_equivalent_follows_configured_setting(service):
    """The unit comes from Settings, not from a constant baked into SAD."""
    from models import Settings

    raw = {'21k': 0.030}
    assert service._main_karat_equivalent(raw) == pytest.approx(0.030, abs=1e-6)

    db.session.add(Settings(main_karat=24))
    db.session.flush()

    # Same grams, different unit: 0.030g of 21k is less gold than 0.030g of 24k.
    assert service._main_karat_equivalent(raw) == pytest.approx(0.030 * 21 / 24, abs=1e-6)


def test_opposite_direction_residuals_do_not_cancel_each_other(service):
    """Magnitudes accumulate: an offsetting pair must not net down to nothing."""
    equivalent = service._main_karat_equivalent({'18k': 0.030, '24k': -0.030})

    signed_would_be = abs(0.030 * 18 / 21 - 0.030 * 24 / 21)
    assert equivalent > signed_would_be
    assert equivalent == pytest.approx(0.030 * 18 / 21 + 0.030 * 24 / 21, abs=1e-6)


def test_tolerance_is_compared_against_the_main_karat_equivalent(
    service, supplier, policy, settlement_accounts
):
    """A karat that converts below the limit passes; its raw grams would not."""
    policy.tolerance_weight = 0.050
    db.session.flush()

    # 0.055g of 18k is above the raw limit but converts to 0.0471g of 21k.
    _give_residual(supplier, karat_field='debit_18k', karat_amount=0.055)
    assert service._main_karat_equivalent({'18k': 0.055}) == pytest.approx(0.0471429, abs=1e-6)

    sad = _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )
    assert sad.status == SupplierSettlementAdjustment.STATUS_POSTED
    # Settled in its own karat, at its raw weight — the conversion measured only.
    assert round(sad.posted_amount_weight_by_karat['18k'], 3) == 0.055


def test_period_cap_accumulates_in_main_karat_equivalent(
    service, supplier, policy, settlement_accounts
):
    """Cumulative consumption is converted before being compared to the cap.

    Chosen so raw-gram accounting and equivalent accounting disagree on the
    outcome: two 0.055g 18k settlements are 0.110 raw (over the 0.100 cap) but
    only 0.0943 in 21k equivalent (under it).
    """
    policy.tolerance_weight = 0.060
    policy.period_cap_weight = 0.100
    db.session.flush()

    for _ in range(2):
        _give_residual(supplier, karat_field='debit_18k', karat_amount=0.055)
        _post_adjustment(
            service, supplier,
            reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
        )

    consumed = service._period_weight_consumption(supplier, NOW, None)
    assert consumed == pytest.approx(0.0942857, abs=1e-6)
    assert consumed != pytest.approx(0.110)  # raw summing would have said this

    # A third one crosses the cap once converted.
    _give_residual(supplier, karat_field='debit_18k', karat_amount=0.055)
    with pytest.raises(NotEligibleError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )
    assert 'within_period_cap' in str(exc.value)


def test_period_cap_mixes_karats_through_the_equivalent(
    service, supplier, policy, settlement_accounts
):
    """Consumption booked in one karat limits what another karat may settle."""
    policy.tolerance_weight = 0.060
    policy.period_cap_weight = 0.080
    db.session.flush()

    _give_residual(supplier, karat_field='debit_24k', karat_amount=0.050)
    _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )
    consumed = service._period_weight_consumption(supplier, NOW, None)
    assert consumed == pytest.approx(0.050 * 24 / 21, abs=1e-6)  # 0.0571

    # 0.030g of 21k would push the shared allowance past 0.080.
    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)
    with pytest.raises(NotEligibleError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )
    assert 'within_period_cap' in str(exc.value)


def test_weight_operation_tolerance_blocks_oversized_karat(
    service, supplier, policy, settlement_accounts
):
    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.400)

    with pytest.raises(NotEligibleError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )
    assert 'within_operation_tolerance' in str(exc.value)


def test_law0_identity_holds_for_reversal(service, supplier, policy, settlement_accounts):
    """A reversal satisfies identity 1 while deliberately re-opening the residual."""
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)

    before = _balance(supplier)
    signed_effect = sad.posted_amount_cash  # the reversal undoes -residual

    service.reverse(sad=sad, reversed_by='r', reason='عكس', now=NOW)
    after = _balance(supplier)

    assert round(after['cash'], 2) == round(before['cash'] + signed_effect, 2)
    assert round(after['cash'], 2) == 3.00  # NOT zero — that is the point


# ── Snapshot / concurrency ────────────────────────────────────────────────────

def test_snapshot_mismatch_kicks_back_to_draft_and_writes_nothing(
    service, supplier, policy, settlement_accounts
):
    _give_residual(supplier, cash=3.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    # The balance moves after the draft was approved.
    _give_residual(supplier, cash=1.00)

    je_before = JournalEntry.query.count()
    voucher_before = Voucher.query.count()

    with pytest.raises(SnapshotMismatchError):
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.status == SupplierSettlementAdjustment.STATUS_DRAFT
    assert sad.voucher_id is None
    assert sad.journal_entry_id is None
    assert JournalEntry.query.count() == je_before
    assert Voucher.query.count() == voucher_before


def test_balance_drifting_to_zero_kicks_back_rather_than_dead_ending(
    service, supplier, policy, settlement_accounts
):
    """A residual settled by other means must leave a recalculable document.

    Reporting only "no residual" and leaving the document approved would strand
    it: refresh_snapshot() requires draft, so it could neither be recalculated
    nor posted.
    """
    _give_residual(supplier, cash=3.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    # Someone settles the residual properly before the adjustment is posted.
    _give_residual(supplier, cash=-3.00)
    assert round(_balance(supplier)['cash'], 2) == 0.00

    with pytest.raises(SnapshotMismatchError):
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.status == SupplierSettlementAdjustment.STATUS_DRAFT
    assert sad.voucher_id is None
    # And the document is genuinely recoverable from here.
    service.refresh_snapshot(sad=sad, now=NOW)
    assert sad.balance_before_financial == 0.00


def test_refresh_snapshot_then_post_succeeds(service, supplier, policy, settlement_accounts):
    _give_residual(supplier, cash=3.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    _give_residual(supplier, cash=1.00)

    service.refresh_snapshot(sad=sad, now=NOW)
    service.approve(sad=sad, approved_by='approver', now=NOW)
    sad = service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.status == SupplierSettlementAdjustment.STATUS_POSTED
    assert round(_balance(supplier)['cash'], 2) == 0.00


# ── Reversal ──────────────────────────────────────────────────────────────────

def test_reversal_creates_new_document_and_restores_balance(
    service, supplier, policy, settlement_accounts
):
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)
    assert round(_balance(supplier)['cash'], 2) == 0.00

    reversal = service.reverse(
        sad=sad, reversed_by='reverser', reason='قيد خاطئ', now=NOW,
    )

    assert reversal.id != sad.id
    assert reversal.reversal_of_id == sad.id
    assert reversal.status == SupplierSettlementAdjustment.STATUS_POSTED
    assert sad.status == SupplierSettlementAdjustment.STATUS_REVERSED
    assert sad.reversal_reason == 'قيد خاطئ'
    # The original residual is back — the reversal undid the settlement.
    assert round(_balance(supplier)['cash'], 2) == 3.00


def test_posted_adjustment_cannot_be_cancelled(service, supplier, policy, settlement_accounts):
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)

    with pytest.raises(ValueError, match='reverse'):
        service.cancel(sad=sad, cancelled_by='x', reason='y', now=NOW)


def test_invariant_catches_wrong_reversal_amount(service, supplier, policy, settlement_accounts):
    """RED witness for the reversal path.

    A reversal cannot be guarded by "balance must be zero" — it deliberately
    re-opens the residual. Only the arithmetic identity can police it, which is
    why identity 1 exists separately from identity 2.
    """
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)

    original_builder = service._build_and_post_voucher

    def wrong_amount(*args, **kwargs):
        kwargs['residual_cash'] = kwargs['residual_cash'] * 2  # reverses twice as much
        return original_builder(*args, **kwargs)

    service._build_and_post_voucher = wrong_amount

    with pytest.raises(SettlementInvariantViolation) as exc:
        service.reverse(sad=sad, reversed_by='r', reason='عكس', now=NOW)

    err = exc.value
    assert err.expected_after == 3.00   # restoring the original residual
    assert round(err.balance_after, 2) == 6.00


def test_repeated_post_creates_no_second_document(service, supplier, policy, settlement_accounts):
    """Calling post() again must not produce a duplicate Voucher or JE."""
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)

    voucher_id = sad.voucher_id
    je_count = JournalEntry.query.count()
    voucher_count = Voucher.query.count()

    with pytest.raises(ValueError):
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.voucher_id == voucher_id
    assert JournalEntry.query.count() == je_count
    assert Voucher.query.count() == voucher_count
    assert round(_balance(supplier)['cash'], 2) == 0.00


def test_repeated_reverse_creates_no_second_document(service, supplier, policy, settlement_accounts):
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)
    reversal = service.reverse(sad=sad, reversed_by='r', reason='عكس', now=NOW)

    je_count = JournalEntry.query.count()
    voucher_count = Voucher.query.count()
    sad_count = SupplierSettlementAdjustment.query.count()

    with pytest.raises(ValueError):
        service.reverse(sad=sad, reversed_by='r', reason='عكس ثانٍ', now=NOW)

    assert JournalEntry.query.count() == je_count
    assert Voucher.query.count() == voucher_count
    assert SupplierSettlementAdjustment.query.count() == sad_count
    assert SupplierSettlementAdjustment.query.filter_by(reversal_of_id=sad.id).count() == 1
    # The reversal's own effect stands exactly once.
    assert round(_balance(supplier)['cash'], 2) == 3.00
    assert reversal.status == SupplierSettlementAdjustment.STATUS_POSTED


def test_adjustment_cannot_be_reversed_twice(service, supplier, policy, settlement_accounts):
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)
    service.reverse(sad=sad, reversed_by='r', reason='أول عكس', now=NOW)

    with pytest.raises(ValueError):
        service.reverse(sad=sad, reversed_by='r', reason='عكس ثانٍ', now=NOW)


# ── Limits and policy ─────────────────────────────────────────────────────────

def test_residual_above_review_threshold_is_refused(service, supplier, policy, settlement_accounts):
    """A large residual is an unexplained fact, not a settlement difference."""
    _give_residual(supplier, cash=750.00)

    with pytest.raises(SupplierAccountReviewRequiredError):
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )


def test_review_error_carries_structured_payload(service, supplier, policy, settlement_accounts):
    """The refusal must tell the UI what to review, without parsing a message."""
    _give_residual(supplier, cash=750.00, karat_field='debit_21k', karat_amount=0.400)

    with pytest.raises(SupplierAccountReviewRequiredError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )

    err = exc.value
    assert err.supplier_id == supplier.id
    assert round(err.current_cash_residual, 2) == 750.00
    assert round(err.current_weight_residual['21k'], 3) == 0.400
    assert err.review_threshold == 500.00
    assert err.reason == 'RESIDUAL_ABOVE_REVIEW_THRESHOLD'

    payload = err.to_dict()
    assert set(payload) >= {
        'supplier_id', 'current_cash_residual', 'current_weight_residual',
        'review_threshold', 'reason',
    }


def test_review_refusal_writes_absolutely_nothing(service, supplier, policy, settlement_accounts):
    """No Voucher, no JE, no balance mutation, and the residual is untouched."""
    _give_residual(supplier, cash=750.00)

    je_before = JournalEntry.query.count()
    voucher_before = Voucher.query.count()
    sad_before = SupplierSettlementAdjustment.query.count()
    balance_before = _balance(supplier)['cash']
    supplier_cols_before = (supplier.balance_cash, supplier.gold_balance_weight)

    with pytest.raises(SupplierAccountReviewRequiredError):
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )

    assert JournalEntry.query.count() == je_before
    assert Voucher.query.count() == voucher_before
    assert SupplierSettlementAdjustment.query.count() == sad_before
    # The residual is neither reduced nor recalculated away.
    assert _balance(supplier)['cash'] == balance_before
    assert (supplier.balance_cash, supplier.gold_balance_weight) == supplier_cols_before


def test_review_threshold_refusal_at_post_is_typed(service, supplier, policy, settlement_accounts):
    """post() distinguishes 'needs review' from ordinary ineligibility."""
    _give_residual(supplier, cash=3.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    # Balance grows past the review threshold before posting.
    _give_residual(supplier, cash=800.00)

    with pytest.raises(SupplierAccountReviewRequiredError):
        service.post(sad=sad, posted_by='poster', now=NOW)
    assert sad.voucher_id is None


def test_operation_tolerance_blocks_oversized_single_adjustment(
    service, supplier, policy, settlement_accounts
):
    _give_residual(supplier, cash=40.00)  # under review threshold, over tolerance

    with pytest.raises(NotEligibleError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )
    assert 'within_operation_tolerance' in str(exc.value)


def test_period_cap_accumulates_across_adjustments(service, supplier, policy, settlement_accounts):
    """Ten 5-SAR settlements in one month exhaust the 50-SAR cap."""
    policy.tolerance_cash = 5.00
    policy.period_cap_cash = 12.00
    db.session.flush()

    for _ in range(2):
        _give_residual(supplier, cash=5.00)
        _post_adjustment(service, supplier)

    consumed = service._period_consumption(supplier, NOW, None)
    assert round(consumed, 2) == 10.00

    _give_residual(supplier, cash=5.00)
    with pytest.raises(NotEligibleError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )
    assert 'within_period_cap' in str(exc.value)


def test_reversed_adjustment_does_not_consume_period_cap(
    service, supplier, policy, settlement_accounts
):
    _give_residual(supplier, cash=5.00)
    sad = _post_adjustment(service, supplier)
    assert round(service._period_consumption(supplier, NOW, None), 2) == 5.00

    service.reverse(sad=sad, reversed_by='r', reason='ملغاة', now=NOW)

    # Net effect is zero, so the allowance is released.
    assert round(service._period_consumption(supplier, NOW, None), 2) == 0.00


def test_new_supplier_activity_blocks_posting_without_kicking_back(
    service, supplier, policy, settlement_accounts
):
    """Activity appearing after approval blocks the post but keeps the approval.

    The snapshot is still accurate here — the blocker is elsewhere — so the
    document stays approved rather than being sent back for recalculation.
    """
    _give_residual(supplier, cash=3.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    # A pending voucher appears for this supplier — no balance impact yet.
    db.session.add(Voucher(
        voucher_number='PV-TEST-SAD-ACTIVITY',
        voucher_type='payment',
        date=NOW,
        status='pending',
        party_type='supplier',
        supplier_id=supplier.id,
        amount_cash=10.0,
        created_by='someone',
    ))
    db.session.flush()

    with pytest.raises(NotEligibleError) as exc:
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert 'no_pending_vouchers' in str(exc.value)
    assert sad.status == SupplierSettlementAdjustment.STATUS_APPROVED
    assert sad.voucher_id is None


def test_snapshot_kick_back_voids_the_stale_approval(
    service, supplier, policy, settlement_accounts
):
    """An approval given for a balance that no longer exists must not survive."""
    _give_residual(supplier, cash=3.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)
    assert sad.approved_by == 'approver'

    _give_residual(supplier, cash=2.00)

    with pytest.raises(SnapshotMismatchError):
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.status == SupplierSettlementAdjustment.STATUS_DRAFT
    assert sad.approved_by is None
    assert sad.approved_at is None
    assert sad.approved_by_manager is False


def test_policy_id_is_frozen_on_the_document(service, supplier, policy, settlement_accounts):
    """The policy that actually decided is recorded, and later edits don't rewrite history."""
    _give_residual(supplier, cash=3.00)
    sad = _post_adjustment(service, supplier)

    assert sad.policy_id == policy.id

    # Finance closes that policy and starts a new one.
    policy.effective_to = NOW + timedelta(seconds=1)
    successor = SupplierSettlementPolicy(
        tolerance_cash=1.00, tolerance_weight=0.01,
        period_cap_cash=10.00, period_cap_weight=0.1,
        review_threshold_cash=100.00,
        effective_from=NOW + timedelta(seconds=1),
        created_by='test',
    )
    db.session.add(successor)
    db.session.flush()

    # The posted document still points at the policy in force when it posted.
    assert sad.policy_id == policy.id
    assert sad.policy_id != successor.id


def test_mid_month_policy_change_applies_whole_month_cap(
    service, supplier, policy, settlement_accounts
):
    """The cap in force at post() governs the entire month's accumulation.

    No proration, and no separate bucket per policy version: consumption booked
    under the previous policy still counts against the current policy's cap.
    """
    policy.tolerance_cash = 5.00
    policy.period_cap_cash = 50.00
    db.session.flush()

    for _ in range(2):
        _give_residual(supplier, cash=5.00)
        _post_adjustment(service, supplier)
    assert round(service._period_consumption(supplier, NOW, None), 2) == 10.00

    # Mid-month tightening: new cap is below what is already consumed.
    policy.effective_to = NOW
    tightened = SupplierSettlementPolicy(
        tolerance_cash=5.00, tolerance_weight=0.05,
        period_cap_cash=8.00, period_cap_weight=0.5,
        review_threshold_cash=500.00,
        effective_from=NOW,
        created_by='test',
    )
    db.session.add(tightened)
    db.session.flush()

    _give_residual(supplier, cash=5.00)
    with pytest.raises(NotEligibleError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )
    assert 'within_period_cap' in str(exc.value)


def test_period_consumption_is_deterministic_and_idempotent(
    service, supplier, policy, settlement_accounts
):
    _give_residual(supplier, cash=5.00)
    _post_adjustment(service, supplier)

    readings = [round(service._period_consumption(supplier, NOW, None), 2) for _ in range(3)]
    assert readings == [5.00, 5.00, 5.00]


def test_policy_is_read_live_at_post_time(service, supplier, settlement_accounts):
    """The policy in force at post() governs, not the one at draft time."""
    lenient = SupplierSettlementPolicy(
        tolerance_cash=100.00, tolerance_weight=1.0,
        period_cap_cash=1000.00, period_cap_weight=10.0,
        review_threshold_cash=500.00,
        effective_from=NOW - timedelta(days=30),
        created_by='test',
    )
    db.session.add(lenient)
    db.session.flush()

    _give_residual(supplier, cash=40.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    # Finance tightens the limit before the document is posted.
    lenient.effective_to = NOW - timedelta(seconds=1)
    strict = SupplierSettlementPolicy(
        tolerance_cash=5.00, tolerance_weight=0.05,
        period_cap_cash=50.00, period_cap_weight=0.5,
        review_threshold_cash=500.00,
        effective_from=NOW - timedelta(seconds=1),
        created_by='test',
    )
    db.session.add(strict)
    db.session.flush()

    with pytest.raises(NotEligibleError) as exc:
        service.post(sad=sad, posted_by='poster', now=NOW)
    assert 'within_operation_tolerance' in str(exc.value)


# ── Refusals that protect the ledger ──────────────────────────────────────────

def test_missing_accounting_mapping_refuses_and_writes_nothing(service, supplier, policy):
    """No mapping configured → refuse. Never post to a guessed account."""
    _give_residual(supplier, cash=3.00)
    je_before = JournalEntry.query.count()

    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    with pytest.raises(MissingAccountingMappingError):
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.voucher_id is None
    assert JournalEntry.query.count() == je_before


def test_weight_only_residual_settles_into_the_memo_account(
    service, supplier, policy, settlement_accounts
):
    """A weight residual alone is settleable, and lands on the parallel account.

    This asserts the actual destination account of the journal line, not merely
    that posting succeeded: the gold line must reach the supplier's memo account
    (reached through the account pair), never the financial one.
    """
    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)
    assert round(_balance(supplier)['21k'], 3) == 0.030

    sad = _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )

    assert round(_balance(supplier)['21k'], 3) == 0.000
    assert round(_balance(supplier)['cash'], 2) == 0.00

    accounts = ensure_supplier_accounts(supplier)
    je_lines = JournalEntryLine.query.filter_by(journal_entry_id=sad.journal_entry_id).all()

    supplier_line = next(l for l in je_lines if l.account_id == accounts.memo.id)
    # Positive residual → the supplier's weight account is credited.
    assert round(supplier_line.credit_21k, 3) == 0.030
    assert supplier_line.debit_21k == 0
    assert supplier_line.supplier_id == supplier.id
    # Grams only: the weight settlement never touches the cash columns.
    assert supplier_line.cash_debit == 0
    assert supplier_line.cash_credit == 0

    # And nothing was posted to the supplier's financial account.
    assert not [l for l in je_lines if l.account_id == accounts.financial.id]

    counter_line = next(
        l for l in je_lines
        if l.account_id == settlement_accounts['weight_expense_memo'].id
    )
    assert round(counter_line.debit_21k, 3) == 0.030
    assert counter_line.cash_debit == 0


def test_negative_weight_residual_reverses_the_direction(
    service, supplier, policy, settlement_accounts
):
    """We owe the supplier grams → Dr supplier memo / Cr weight settlement income."""
    _give_residual(supplier, karat_field='credit_21k', karat_amount=0.030)
    assert round(_balance(supplier)['21k'], 3) == -0.030

    sad = _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )

    assert round(_balance(supplier)['21k'], 3) == 0.000

    accounts = ensure_supplier_accounts(supplier)
    je_lines = JournalEntryLine.query.filter_by(journal_entry_id=sad.journal_entry_id).all()

    supplier_line = next(l for l in je_lines if l.account_id == accounts.memo.id)
    assert round(supplier_line.debit_21k, 3) == 0.030
    assert supplier_line.credit_21k == 0

    counter_line = next(
        l for l in je_lines
        if l.account_id == settlement_accounts['weight_income_memo'].id
    )
    assert round(counter_line.credit_21k, 3) == 0.030


def test_cash_and_weight_settle_together_in_one_adjustment(
    service, supplier, policy, settlement_accounts
):
    """Both sides close in a single document, each to its own account."""
    _give_residual(supplier, cash=3.00, karat_field='debit_21k', karat_amount=0.030)

    sad = _post_adjustment(service, supplier)

    balance = _balance(supplier)
    assert round(balance['cash'], 2) == 0.00
    assert round(balance['21k'], 3) == 0.000

    accounts = ensure_supplier_accounts(supplier)
    je_lines = JournalEntryLine.query.filter_by(journal_entry_id=sad.journal_entry_id).all()
    assert len(je_lines) == 4  # one pair for cash, one for the karat

    cash_line = next(l for l in je_lines if l.account_id == accounts.financial.id)
    assert round(cash_line.cash_credit, 2) == 3.00

    weight_line = next(l for l in je_lines if l.account_id == accounts.memo.id)
    assert round(weight_line.credit_21k, 3) == 0.030

    # The document records both settled sides.
    assert round(sad.posted_amount_cash, 2) == 3.00
    assert round(sad.posted_amount_weight_by_karat['21k'], 3) == 0.030


def test_main_karat_does_not_change_the_posting_account_or_karat_column(
    service, supplier, policy, settlement_accounts
):
    """Normalization is measurement only — it never reaches the journal.

    An 18k residual must post as 18k grams, on the supplier's parallel memo
    account. It must NOT be converted into a main-karat amount, and it must NOT
    be redirected to some other account because of the conversion.
    """
    policy.tolerance_weight = 0.060
    db.session.flush()

    _give_residual(supplier, karat_field='debit_18k', karat_amount=0.050)

    sad = _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )

    accounts = ensure_supplier_accounts(supplier)
    je_lines = JournalEntryLine.query.filter_by(journal_entry_id=sad.journal_entry_id).all()
    supplier_line = next(l for l in je_lines if l.account_id == accounts.memo.id)

    # Posted in the ORIGINAL karat column, at the ORIGINAL weight.
    assert round(supplier_line.credit_18k, 3) == 0.050
    # Not converted into the main-karat column, and not spread anywhere else.
    assert supplier_line.credit_21k == 0
    assert supplier_line.debit_21k == 0
    assert supplier_line.cash_debit == 0 and supplier_line.cash_credit == 0

    # Still the account-pair destination, unaffected by the conversion.
    assert accounts.memo.tracks_weight is True
    assert accounts.financial.memo_account_id == accounts.memo.id
    assert not [l for l in je_lines if l.account_id == accounts.financial.id]

    # The stored raw weight is the original karat's grams, not the equivalent.
    assert round(sad.posted_amount_weight_by_karat['18k'], 3) == 0.050
    assert service._main_karat_equivalent({'18k': 0.050}) != pytest.approx(0.050)


def test_multiple_karats_each_settle_to_their_own_column(
    service, supplier, policy, settlement_accounts
):
    """Karats are settled independently and never merged into one amount."""
    policy.tolerance_weight = 0.100
    db.session.flush()

    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)
    _give_residual(supplier, karat_field='credit_18k', karat_amount=0.020)
    _give_residual(supplier, karat_field='debit_24k', karat_amount=0.010)

    sad = _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )

    balance = _balance(supplier)
    assert round(balance['21k'], 3) == 0.000
    assert round(balance['18k'], 3) == 0.000
    assert round(balance['24k'], 3) == 0.000
    assert round(balance['22k'], 3) == 0.000

    accounts = ensure_supplier_accounts(supplier)
    je_lines = JournalEntryLine.query.filter_by(journal_entry_id=sad.journal_entry_id).all()
    supplier_lines = [l for l in je_lines if l.account_id == accounts.memo.id]
    assert len(supplier_lines) == 3

    # Opposite signs are preserved per karat — 18k was the other direction.
    assert round(sum(l.credit_21k for l in supplier_lines), 3) == 0.030
    assert round(sum(l.debit_18k for l in supplier_lines), 3) == 0.020
    assert round(sum(l.credit_24k for l in supplier_lines), 3) == 0.010

    # 18k used the income side while 21k/24k used the expense side.
    assert any(
        l.account_id == settlement_accounts['weight_income_memo'].id for l in je_lines
    )
    assert any(
        l.account_id == settlement_accounts['weight_expense_memo'].id for l in je_lines
    )

    # No line carries a main-karat total: the equivalent exists only as a measure.
    # 0.020*18/21 + 0.030 + 0.010*24/21 — not the 0.060 a raw sum would give.
    equivalent = service._main_karat_equivalent(sad.posted_amount_weight_by_karat)
    assert equivalent == pytest.approx(0.0585714, abs=1e-6)
    assert equivalent != pytest.approx(0.060)
    assert not [
        l for l in supplier_lines
        if round(l.debit_21k, 6) == round(equivalent, 6)
        or round(l.credit_21k, 6) == round(equivalent, 6)
    ]


def test_multi_karat_reversal_reopens_each_original_karat(
    service, supplier, policy, settlement_accounts
):
    """Reversal mirrors the original karats, not their main-karat equivalent."""
    policy.tolerance_weight = 0.100
    db.session.flush()

    _give_residual(supplier, karat_field='debit_18k', karat_amount=0.010)
    _give_residual(supplier, karat_field='debit_24k', karat_amount=0.020)

    sad = _post_adjustment(
        service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )
    assert round(_balance(supplier)['18k'], 3) == 0.000
    assert round(_balance(supplier)['24k'], 3) == 0.000

    reversal = service.reverse(sad=sad, reversed_by='r', reason='عكس', now=NOW)

    balance = _balance(supplier)
    # Each original karat is re-opened at its own original weight.
    assert round(balance['18k'], 3) == 0.010
    assert round(balance['24k'], 3) == 0.020
    assert round(balance['21k'], 3) == 0.000  # nothing landed in the main karat

    assert round(reversal.posted_amount_weight_by_karat['18k'], 3) == -0.010
    assert round(reversal.posted_amount_weight_by_karat['24k'], 3) == -0.020

    # And the reversal released the allowance it had consumed.
    assert service._period_weight_consumption(supplier, NOW, None) == pytest.approx(0.0)


def test_weight_settlement_has_no_monetary_or_inventory_effect(
    service, supplier, policy, settlement_accounts, monkeypatch
):
    """Grams close grams: no valuation, no costing call, no inventory movement.

    Guards the explicit prohibitions — no SAR conversion, no gold price read,
    no GoldCostingService, no COGS, no inventory adjustment.
    """
    from models import InventoryCostingConfig, InventoryLedger
    import gold_costing_service

    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)

    costing_before = [
        (c.id, c.total_inventory_weight, c.total_gold_value,
         c.total_manufacturing_value, c.avg_total_cost_per_gram)
        for c in InventoryCostingConfig.query.all()
    ]
    ledger_before = InventoryLedger.query.count()

    calls = []
    for name in ('update_average_on_purchase', 'consume_inventory', 'calculate_cogs'):
        def _boom(*a, _name=name, **kw):
            calls.append(_name)
            raise AssertionError(f'GoldCostingService.{_name} must never be called by SAD')

        monkeypatch.setattr(
            gold_costing_service.GoldCostingService, name, staticmethod(_boom),
        )

    sad = _post_adjustment(
        service, supplier,
        reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
    )

    assert calls == []
    assert round(_balance(supplier)['21k'], 3) == 0.000

    costing_after = [
        (c.id, c.total_inventory_weight, c.total_gold_value,
         c.total_manufacturing_value, c.avg_total_cost_per_gram)
        for c in InventoryCostingConfig.query.all()
    ]
    assert costing_after == costing_before
    assert InventoryLedger.query.count() == ledger_before

    # No cash amount was derived from the weight anywhere on the document.
    assert (sad.posted_amount_cash or 0.0) == 0.0
    assert sad.voucher.amount_cash == 0.0

    je_lines = JournalEntryLine.query.filter_by(journal_entry_id=sad.journal_entry_id).all()
    assert all(l.cash_debit == 0 and l.cash_credit == 0 for l in je_lines)


def test_weight_mapping_to_a_non_weight_account_is_refused(
    service, supplier, policy, settlement_accounts
):
    """A mapping that cannot carry grams must fail loudly, not post silently."""
    plain = Account(
        account_number='5903', name='حساب مالي بلا موازٍ',
        type='Expense', tracks_weight=False,
    )
    db.session.add(plain)
    db.session.flush()

    mapping = AccountingMapping.query.filter_by(
        operation_type=SETTLEMENT_OPERATION_TYPE,
        account_type=ACCOUNT_TYPE_WEIGHT_SETTLEMENT_EXPENSE,
    ).first()
    mapping.account_id = plain.id
    db.session.flush()

    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    je_before = JournalEntry.query.count()
    with pytest.raises(MissingAccountingMappingError, match='لا يتتبع الوزن'):
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.voucher_id is None
    assert JournalEntry.query.count() == je_before


def test_weight_snapshot_mismatch_blocks_posting(
    service, supplier, policy, settlement_accounts
):
    """A karat that moved between draft and post stops the posting."""
    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )
    service.approve(sad=sad, approved_by='approver', now=NOW)

    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.010)

    je_before = JournalEntry.query.count()
    with pytest.raises(SnapshotMismatchError, match='الوزن'):
        service.post(sad=sad, posted_by='poster', now=NOW)

    assert sad.status == SupplierSettlementAdjustment.STATUS_DRAFT
    assert sad.approved_by is None
    assert sad.voucher_id is None
    assert JournalEntry.query.count() == je_before


def test_other_reason_requires_note(service, supplier, policy, settlement_accounts):
    _give_residual(supplier, cash=3.00)

    with pytest.raises(ValueError, match='ملاحظة'):
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_OTHER,
            created_by='tester',
            now=NOW,
        )


def test_other_reason_requires_manager_approval(service, supplier, policy, settlement_accounts):
    _give_residual(supplier, cash=3.00)
    sad = service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_OTHER,
        created_by='tester',
        now=NOW,
        note='تنازل موثق من المورد',
    )

    with pytest.raises(ManagerApprovalRequiredError):
        service.approve(sad=sad, approved_by='clerk', now=NOW, is_manager=False)

    service.approve(sad=sad, approved_by='manager', now=NOW, is_manager=True)
    assert sad.approved_by_manager is True


def test_string_values_fit_their_columns():
    """SAD's string constants still fit their columns — proven elsewhere now.

    The length checks this test used to perform by hand were folded into the
    repository-wide gate in tests/test_string_column_capacity.py, which reads
    every String(n) column from the live metadata instead of SAD's handful.
    Duplicating the arithmetic here would create the second implementation that
    refactor existed to remove.

    What remains is a pointer with teeth: it asserts the general gate actually
    inspects each binding SAD writes. If a future change stops the gate from
    reaching them, this fails inside the SAD suite — where someone touching SAD
    will see it — rather than silently leaving the domain unguarded.
    """
    import sys
    from pathlib import Path

    scripts = Path(__file__).resolve().parents[2] / 'scripts'
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    from string_capacity_guard import run
    from tests.test_string_column_capacity import SAD_BINDINGS

    covered = run().covered
    missing = [b for b in SAD_BINDINGS if b not in covered]
    assert not missing, (
        'the repository-wide string capacity gate no longer covers: '
        + ', '.join(f'{t}.{c}={v!r}' for t, c, v in missing)
    )


def test_purchase_discount_is_not_a_settlement_reason():
    """Purchase discounts affect inventory/cost/VAT and must not enter via SAD."""
    assert 'PURCHASE_DISCOUNT' not in SupplierSettlementAdjustment.VALID_REASON_CODES


def test_second_open_adjustment_is_blocked(service, supplier, policy, settlement_accounts):
    _give_residual(supplier, cash=3.00)
    service.create_draft(
        supplier=supplier,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
        now=NOW,
    )

    with pytest.raises(NotEligibleError) as exc:
        service.create_draft(
            supplier=supplier,
            reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
            created_by='tester',
            now=NOW,
        )
    assert 'no_other_open_adjustments' in str(exc.value)


def test_denormalised_balances_are_never_touched(service, supplier, policy, settlement_accounts):
    """SAD writes the ledger only; cached balance columns are not its business."""
    _give_residual(supplier, cash=3.00)
    before = (
        supplier.balance_cash,
        supplier.gold_balance_weight,
        supplier.gold_balance_cash_equivalent,
    )

    _post_adjustment(service, supplier)

    assert (
        supplier.balance_cash,
        supplier.gold_balance_weight,
        supplier.gold_balance_cash_equivalent,
    ) == before


# ── State machine ─────────────────────────────────────────────────────────────

def test_invalid_transition_is_rejected(supplier):
    sad = SupplierSettlementAdjustment(
        adjustment_number='SAD-2026-99999',
        supplier_id=supplier.id,
        status=SupplierSettlementAdjustment.STATUS_DRAFT,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
    )
    # draft → posted skips approval
    with pytest.raises(ValueError, match='انتقال غير مسموح'):
        sad._transition(SupplierSettlementAdjustment.STATUS_POSTED)


def test_reversed_is_terminal(supplier):
    sad = SupplierSettlementAdjustment(
        adjustment_number='SAD-2026-99998',
        supplier_id=supplier.id,
        status=SupplierSettlementAdjustment.STATUS_REVERSED,
        reason_code=SupplierSettlementAdjustment.REASON_ROUNDING_DIFFERENCE,
        created_by='tester',
    )
    assert sad.is_terminal is True
    with pytest.raises(ValueError):
        sad._transition(SupplierSettlementAdjustment.STATUS_POSTED)
