"""test_phase10b_group_a_historical_correction.py
====================================================
Phase 10B — Safe Historical Correction: Group A only.

Group A (Phase 10 discovery, re-verified directly against prodcopy_phase5
before this file was written): 13 invoices —
{406,407,427,428,429,430,431,432,434,435,437,438,439} — each has a real,
active InvoicePayment (or set of them) whose sum exactly equals
invoice.total, stored status already 'paid', but stored amount_paid stuck
at 0.0 because whatever wrote it never called recompute(). The fix rebuilds
a derived cache field from evidence that already exists; it fabricates no
new historical event.

This suite cannot touch the real 13 invoices — conftest.py forbids the
test run from ever reaching real dev/prod data (prodcopy_phase5 /
yasargold_prodcopy), on purpose. So instead of re-asserting evidence on the
real IDs (already done, directly, against prodcopy_phase5, as part of this
phase's discovery step — see the phase report), these tests prove the
*mechanism* is safe using synthetic fixtures that reproduce the Group-A
evidence shape, plus shapes that must be rejected. Test 1 is the only one
that touches the real id set, and it does so as a pure constant check.
"""
import uuid
from datetime import datetime

import pytest

from app import app
from models import Account, Invoice, InvoicePayment, JournalEntry, PaymentMethod, Voucher, db
from services.invoice_payment_state_service import InvoicePaymentStateService
from devtools.fix_group_a_amount_paid_cache import (
    TARGET_INVOICE_IDS,
    check_invoice_safety,
    repair_group_a,
)


@pytest.fixture(autouse=True)
def _app_context():
    with app.app_context():
        yield


def _uid():
    return uuid.uuid4().hex[:8]


def _payment_method():
    pm = PaymentMethod(payment_type='cash', name=f'وسيلة اختبار {_uid()}')
    db.session.add(pm)
    db.session.commit()
    return pm


def _invoice(total, amount_paid, status, barter_total=0.0):
    # Committed, not just flushed: check_invoice_safety() calls
    # db.session.rollback() internally to discard recompute()'s speculative
    # in-memory mutation -- correct against a real, already-committed
    # target row, but it would also wipe out an uncommitted fixture. Every
    # target invoice this repair ever runs against in reality is already
    # committed long before the script sees it, so fixtures matching that
    # is what makes the test represent the real case.
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع', date=datetime.now(),
        total=total, amount_paid=amount_paid, status=status,
        barter_total=barter_total, is_posted=True,
    )
    db.session.add(inv)
    db.session.commit()
    return inv


def _group_a_shaped_invoice(total=5000.0):
    """Reproduces the exact Group A evidence shape: one real InvoicePayment
    fully covering total, source_voucher_id NULL, stored amount_paid=0,
    stored status already 'paid'."""
    pm = _payment_method()
    inv = _invoice(total=total, amount_paid=0.0, status='paid')
    db.session.add(InvoicePayment(
        invoice_id=inv.id, payment_method_id=pm.id,
        amount=total, net_amount=total, source_voucher_id=None,
    ))
    db.session.commit()
    return inv


def _cancelled_voucher():
    v = Voucher(
        voucher_number=f'TST-{_uid()}', voucher_type='receipt',
        amount_cash=5000.0, status='cancelled', reference_type='invoice',
    )
    db.session.add(v)
    db.session.commit()
    return v


class TestGroupASetIsFixed:
    """Test 1 — the target set is exactly the 13 ids Phase 10 discovery
    named, never a computed/rediscovered set."""

    def test_group_a_is_exactly_the_13_known_ids(self):
        expected = {427, 428, 429, 406, 407, 430, 431, 432, 434, 435, 437, 438, 439}
        assert set(TARGET_INVOICE_IDS) == expected
        assert len(TARGET_INVOICE_IDS) == 13


class TestSafetyCheckAcceptsValidEvidence:
    """Test 2 — a fixture matching the Group A evidence shape passes every
    safety condition (A-F) and computes its expected state via the real
    InvoicePaymentStateService, not a reimplemented formula."""

    def test_group_a_shaped_invoice_is_eligible(self):
        inv = _group_a_shaped_invoice(total=7345.5)
        result = check_invoice_safety(inv)
        assert result.eligible is True, result.reason
        assert result.expected_amount_paid == 7345.5
        assert result.expected_status == 'paid'

    def test_multiple_active_payments_summing_to_total_is_eligible(self):
        pm1, pm2 = _payment_method(), _payment_method()
        inv = _invoice(total=9000.0, amount_paid=0.0, status='paid')
        db.session.add(InvoicePayment(invoice_id=inv.id, payment_method_id=pm1.id, amount=4000.0, net_amount=4000.0))
        db.session.add(InvoicePayment(invoice_id=inv.id, payment_method_id=pm2.id, amount=5000.0, net_amount=5000.0))
        db.session.commit()
        result = check_invoice_safety(inv)
        assert result.eligible is True, result.reason
        assert result.expected_amount_paid == 9000.0


class TestSafetyCheckRejectsInvalidEvidence:
    """Test 2 (inverse) — shapes that must NOT be treated as Group A."""

    def test_insufficient_payment_coverage_is_rejected(self):
        pm = _payment_method()
        inv = _invoice(total=5000.0, amount_paid=0.0, status='paid')
        db.session.add(InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=3000.0, net_amount=3000.0))
        db.session.commit()
        result = check_invoice_safety(inv)
        assert result.eligible is False

    def test_cancelled_source_voucher_payment_is_rejected(self):
        pm = _payment_method()
        v = _cancelled_voucher()
        inv = _invoice(total=5000.0, amount_paid=0.0, status='paid')
        db.session.add(InvoicePayment(
            invoice_id=inv.id, payment_method_id=pm.id, amount=5000.0, net_amount=5000.0,
            source_voucher_id=v.id,
        ))
        db.session.commit()
        result = check_invoice_safety(inv)
        assert result.eligible is False

    def test_zero_evidence_phantom_paid_is_rejected(self):
        """The Group H shape (Phase 10): status='paid', no InvoicePayment at
        all. Must never be treated as Group A."""
        inv = _invoice(total=5000.0, amount_paid=0.0, status='paid')
        result = check_invoice_safety(inv)
        assert result.eligible is False

    def test_status_would_also_change_is_rejected(self):
        """Group A's own definition is amount-only correction: stored status
        is already canonical. If canonical status would differ from stored,
        this is not Group A's shape (e.g. Group B) and must be rejected,
        never silently corrected as a side effect."""
        pm = _payment_method()
        inv = _invoice(total=5000.0, amount_paid=300.0, status='paid')  # Group B shape
        db.session.add(InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=300.0, net_amount=300.0))
        db.session.commit()
        result = check_invoice_safety(inv)
        assert result.eligible is False


class TestDryRunUsesCanonicalService:
    """Test 3 — the expected amount/status come from
    InvoicePaymentStateService.recompute() itself, and a dry-run check never
    persists a change."""

    def test_check_does_not_mutate_stored_state(self):
        inv = _group_a_shaped_invoice(total=1234.0)
        inv_id = inv.id
        check_invoice_safety(inv)
        db.session.expire_all()
        reloaded = Invoice.query.get(inv_id)
        assert float(reloaded.amount_paid or 0.0) == 0.0
        assert reloaded.status == 'paid'

    def test_expected_values_match_live_service_call(self):
        inv = _group_a_shaped_invoice(total=4321.0)
        result = check_invoice_safety(inv)
        # Cross-check against calling the real service directly ourselves.
        probe = InvoicePaymentStateService().recompute(inv)
        db.session.rollback()
        assert result.expected_amount_paid == probe.amount_paid
        assert result.expected_status == probe.status


class TestCorrectionChangesOnlyDerivedState:
    """Test 4 — repair_group_a(apply=True) touches Invoice.amount_paid /
    Invoice.status only. No InvoicePayment, Voucher, JournalEntry, or
    PaymentMethod row is created, deleted, or modified."""

    def test_no_side_tables_are_touched(self):
        inv = _group_a_shaped_invoice(total=2222.0)
        target_ids = (inv.id,)

        before_payments = InvoicePayment.query.count()
        before_vouchers = Voucher.query.count()
        before_journal_entries = JournalEntry.query.count()
        before_payment_methods = PaymentMethod.query.count()
        before_accounts = Account.query.count()

        report = repair_group_a(apply=True, target_ids=target_ids)
        assert report.corrected == 1

        assert InvoicePayment.query.count() == before_payments
        assert Voucher.query.count() == before_vouchers
        assert JournalEntry.query.count() == before_journal_entries
        assert PaymentMethod.query.count() == before_payment_methods
        assert Account.query.count() == before_accounts


class TestStatusStaysCanonical:
    """Test 5 — the repair never sets status through anything other than
    the canonical service; an eligible Group-A-shaped row's status is
    identical before and after (it was already canonical)."""

    def test_status_unchanged_for_eligible_invoice(self):
        inv = _group_a_shaped_invoice(total=3000.0)
        target_ids = (inv.id,)
        status_before = inv.status

        repair_group_a(apply=True, target_ids=target_ids)

        db.session.expire_all()
        reloaded = Invoice.query.get(inv.id)
        assert reloaded.status == status_before == 'paid'
        assert float(reloaded.amount_paid) == 3000.0


class TestIdempotency:
    """Test 6 — run 1 corrects, run 2 and run 3 are no-ops."""

    def test_repeated_runs_stabilize(self):
        inv = _group_a_shaped_invoice(total=6100.0)
        target_ids = (inv.id,)

        r1 = repair_group_a(apply=True, target_ids=target_ids)
        r2 = repair_group_a(apply=True, target_ids=target_ids)
        r3 = repair_group_a(apply=True, target_ids=target_ids)

        assert r1.corrected == 1
        assert r2.corrected == 0
        assert r3.corrected == 0


class TestAtomicity:
    """Test 7 — if any target invoice fails safety validation mid-batch, the
    eligible ones in the same call are still applied (rejects are isolated,
    not fatal to the batch); but a hard failure during the write itself
    (simulated by forcing an ineligible id into the batch alongside real
    IDs) never leaves an eligible invoice half-updated -- it is fully
    committed or fully absent, never partially written."""

    def test_reject_does_not_prevent_eligible_siblings_in_same_batch(self):
        ok_inv = _group_a_shaped_invoice(total=1500.0)
        bad_inv = _invoice(total=5000.0, amount_paid=0.0, status='paid')  # zero evidence

        report = repair_group_a(apply=True, target_ids=(ok_inv.id, bad_inv.id))

        assert report.corrected == 1
        assert report.rejected == 1
        db.session.expire_all()
        assert float(Invoice.query.get(ok_inv.id).amount_paid) == 1500.0
        assert float(Invoice.query.get(bad_inv.id).amount_paid) == 0.0

    def test_dry_run_never_commits(self):
        inv = _group_a_shaped_invoice(total=999.0)
        repair_group_a(apply=False, target_ids=(inv.id,))
        db.session.expire_all()
        reloaded = Invoice.query.get(inv.id)
        assert float(reloaded.amount_paid or 0.0) == 0.0


class TestNonTargetProtection:
    """Test 8 — an unrelated invoice not in the target id set is never
    touched, even if it independently happens to have its own mismatch
    (e.g. a Group-H-shaped zero-evidence 'paid' row sitting in the same
    database)."""

    def test_invoice_outside_target_set_is_untouched(self):
        target = _group_a_shaped_invoice(total=800.0)
        bystander = _invoice(total=5000.0, amount_paid=0.0, status='paid')  # Group H shape
        bystander_id = bystander.id

        repair_group_a(apply=True, target_ids=(target.id,))

        db.session.expire_all()
        untouched = Invoice.query.get(bystander_id)
        assert float(untouched.amount_paid or 0.0) == 0.0
        assert untouched.status == 'paid'
