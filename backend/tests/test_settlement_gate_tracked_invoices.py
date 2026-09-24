"""Phase (ب) — the SAD gate must stop asking a question the data cannot answer.

`_check_no_unpaid_invoices` refused a settlement whenever the supplier had ANY
invoice reading 'unpaid' or 'partially_paid'. On production-copy data that gate
blocked 22 of the 27 suppliers carrying a residual, and it blocked them on a field
that is stale by construction:

    open invoice cash claimed : 1,834,663 SAR   vs   ledger owes :  90,439 SAR
    open invoice gold claimed :    20,692 g     vs   ledger owes :   1,309 g

Supplier #9 is the whole story in one row — three invoices claim 28,290 SAR open,
the ledger carries 1.33. The money was paid through vouchers that were never
linked to an invoice (168 approved supplier vouchers carry no reference_type at
all), and ADR-028 forbids inferring that link. So the status can never be
corrected automatically, and a gate reading it can never be satisfied.

THE CONTRACT THIS FILE PINS:

    unpaid/partial AND invoice-level tracked   -> block
    unpaid/partial AND NOT tracked             -> ignore (status is unknowable)

THE RED WITNESSES are the four `no_longer_blocks` tests.

THE LOAD-BEARING TEST is TestTheLedgerStillGuards: relaxing this gate must not
open a single riyal beyond what the GL limits already allow. The protection moves
from a stale flag to the ledger — it does not disappear. Without that witness this
change is indistinguishable from removing a control.

Run:
    python -m pytest tests/test_settlement_gate_tracked_invoices.py -v
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import (
    Invoice,
    JournalEntry,
    JournalEntryLine,
    Supplier,
    SupplierSettlementAdjustment as SAD,
    SupplierSettlementPolicy,
    db,
)
from party_account_service import ensure_supplier_accounts
from services.supplier_settlement_adjustment_service import (
    SupplierSettlementAdjustmentService,
)

GATE = 'no_unpaid_invoices'
NOW = datetime(2026, 9, 25, 10, 0, 0)


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


def _uid():
    return uuid.uuid4().hex[:8]


@pytest.fixture
def policy():
    p = SupplierSettlementPolicy(
        tolerance_cash=5.0, tolerance_weight=0.05,
        period_cap_cash=50.0, period_cap_weight=0.5,
        review_threshold_cash=500.0,
        effective_from=NOW - timedelta(days=30), created_by='test',
    )
    db.session.add(p)
    db.session.flush()
    return p


@pytest.fixture
def supplier():
    s = Supplier(supplier_code=f'S-GATE-{_uid()}', name=f'مورد بوابة {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


def _give_residual(supplier, *, cash=0.0, karat_field=None, karat_amount=0.0):
    accounts = ensure_supplier_accounts(supplier)
    je = JournalEntry(
        entry_number=f'JE-GATE-{_uid()}', date=NOW - timedelta(days=1),
        description='رصيد اختباري', entry_type='عادي',
        is_posted=True, is_draft=False, created_by='test',
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


def _invoice(supplier, *, status, tracked, invoice_type='شراء', office_id=None):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type=invoice_type,
        supplier_id=supplier.id, office_id=office_id,
        date=NOW - timedelta(days=10),
        total=100000.0, wage_subtotal=5000.0,
        status=status, amount_paid=0.0, is_posted=True,
        gold_settlement_tracked=tracked,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _checks(supplier, policy, reason_code=SAD.REASON_ROUNDING_DIFFERENCE):
    result = SupplierSettlementAdjustmentService().check_eligibility(
        supplier, now=NOW, policy=policy, reason_code=reason_code,
    )
    return {c.name: c for c in result.checks}


def _gate_passed(supplier, policy):
    return _checks(supplier, policy)[GATE].passed


# ======================================================================
# THE RED WITNESSES — untracked status is not evidence of anything
# ======================================================================

class TestUntrackedInvoicesNoLongerBlock:

    def test_an_untracked_unpaid_invoice_no_longer_blocks(self):
        """The 135 real 'unpaid' rows. Their payment happened in the ledger and
        was never written onto the invoice; nothing can tell them apart from a
        genuinely open one, so they may not decide a settlement."""
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        _invoice(s, status='unpaid', tracked=False)

        assert _gate_passed(s, p), \
            'an invoice outside invoice-level enforcement cannot veto a settlement'

    def test_an_untracked_partially_paid_invoice_no_longer_blocks(self):
        """The 27 real 'partially_paid' rows — same reasoning."""
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        _invoice(s, status='partially_paid', tracked=False)

        assert _gate_passed(s, p)

    def test_a_purchase_return_no_longer_blocks(self):
        """3 of the 162 blocking rows are 'مرتجع شراء (مورد)'. A return is never
        gold-tracked, so it was vetoing settlements while reducing what we owe."""
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        _invoice(s, status='unpaid', tracked=False,
                 invoice_type='مرتجع شراء (مورد)')

        assert _gate_passed(s, p)

    def test_an_office_invoice_no_longer_blocks(self):
        """An office settlement invoice is never tracked by design —
        is_gold_obligation_eligible() returns False for office_id, because that
        flow posts cash only and has zero gold liability in the GL.

        Its CASH obligation is real, and this gate stops representing it. What
        represents it instead is the ledger: an unpaid office invoice leaves the
        obligation in the supplier's balance, where the review threshold and the
        tolerance meet it. TestTheLedgerStillGuards proves that is not a gap.
        """
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        _invoice(s, status='unpaid', tracked=False, office_id=1)

        assert _gate_passed(s, p)

    # Bound the fixtures to the class so each test reads as one statement.
    @pytest.fixture(autouse=True)
    def _bind(self, supplier, policy):
        self.supplier, self.policy = supplier, policy


# ======================================================================
# What the gate still refuses — the half that must not move
# ======================================================================

class TestTrackedInvoicesStillBlock:

    @pytest.fixture(autouse=True)
    def _bind(self, supplier, policy):
        self.supplier, self.policy = supplier, policy

    def test_a_tracked_unpaid_invoice_still_blocks(self):
        """Above the boundary the status IS maintained, so it means what it says:
        a real open obligation, and the residual is that invoice — not a
        difference to write off."""
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        _invoice(s, status='unpaid', tracked=True)

        gate = _checks(s, p)[GATE]
        assert not gate.passed
        assert '1' in gate.detail, 'the refusal says how many invoices caused it'

    def test_a_tracked_partially_paid_invoice_still_blocks(self):
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        _invoice(s, status='partially_paid', tracked=True)

        assert not _gate_passed(s, p)

    def test_a_tracked_paid_invoice_does_not_block(self):
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        _invoice(s, status='paid', tracked=True)

        assert _gate_passed(s, p)

    def test_one_tracked_invoice_blocks_even_among_many_untracked(self):
        """The relaxation is per-invoice, not per-supplier. A single enforced
        invoice still decides."""
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        for _ in range(4):
            _invoice(s, status='unpaid', tracked=False)
        _invoice(s, status='unpaid', tracked=True)

        assert not _gate_passed(s, p)

    def test_only_tracked_invoices_are_counted_in_the_refusal(self):
        s, p = self.supplier, self.policy
        _give_residual(s, cash=3.00)
        for _ in range(6):
            _invoice(s, status='unpaid', tracked=False)
        for _ in range(2):
            _invoice(s, status='unpaid', tracked=True)

        detail = _checks(s, p)[GATE].detail
        assert '2' in detail, f'must count the 2 tracked, not the 8 total: {detail!r}'
        assert '8' not in detail


# ======================================================================
# THE LOAD-BEARING TEST — the protection moved, it did not vanish
# ======================================================================

class TestTheLedgerStillGuards:

    @pytest.fixture(autouse=True)
    def _bind(self, supplier, policy):
        self.supplier, self.policy = supplier, policy

    def test_a_large_residual_is_still_refused_after_the_gate_relaxes(self):
        """The whole risk of phase (ب) in one test.

        A supplier with untracked unpaid invoices and a 20,000 SAR residual now
        clears the invoice gate. It must still be refused — by the review
        threshold, the operation tolerance and the period cap, which read the
        LEDGER. If this passes, (ب) removed a control instead of relocating it.
        """
        s, p = self.supplier, self.policy
        _give_residual(s, cash=20349.37)
        _invoice(s, status='unpaid', tracked=False)

        checks = _checks(s, p)
        assert checks[GATE].passed, 'the gate relaxed, as designed'
        assert not checks['below_review_threshold'].passed
        assert not checks['within_operation_tolerance'].passed
        assert not checks['within_period_cap'].passed

    def test_a_large_gold_residual_is_still_refused(self):
        """Both dimensions. 12.5 g is 250x the 0.05 g tolerance."""
        s, p = self.supplier, self.policy
        _give_residual(s, karat_field='debit_21k', karat_amount=12.500)
        _invoice(s, status='unpaid', tracked=False)

        checks = _checks(s, p)
        assert checks[GATE].passed
        assert not checks['within_operation_tolerance'].passed

    def test_a_small_residual_within_the_limits_becomes_settleable(self):
        """The intended effect, stated as a whole verdict rather than one check:
        supplier #9's real shape — a 1.33 SAR ledger residual behind untracked
        'unpaid' invoices — now passes every gate."""
        s, p = self.supplier, self.policy
        _give_residual(s, cash=1.33)
        _invoice(s, status='unpaid', tracked=False)
        _invoice(s, status='unpaid', tracked=False)

        failed = {name for name, c in _checks(s, p).items() if not c.passed}
        assert failed == set(), f'still refused by: {failed}'

    def test_the_other_eligibility_gates_are_untouched(self):
        """(ب) changes one gate. An unposted journal entry must still refuse."""
        s, p = self.supplier, self.policy
        _give_residual(s, cash=1.33)
        _invoice(s, status='unpaid', tracked=False)

        accounts = ensure_supplier_accounts(s)
        je = JournalEntry(
            entry_number=f'JE-DRAFT-{_uid()}', date=NOW, description='غير مرحّل',
            entry_type='عادي', is_posted=False, is_draft=True, created_by='test',
        )
        db.session.add(je)
        db.session.flush()
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=accounts.financial.id,
            supplier_id=s.id, cash_debit=1.0, description='غير مرحّل',
        ))
        db.session.flush()

        checks = _checks(s, p)
        assert checks[GATE].passed
        assert not checks['no_unposted_journal_entries'].passed
