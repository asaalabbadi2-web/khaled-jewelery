"""Phase 16C — the Gold Advance/Obligation model under the corrected contract.

GL is the Single Source of Truth; the (supplier x karat) position derived from
it is always authoritative; invoice attribution exists ONLY where it can be
evidenced (an explicit GoldAllocation, or a direct-linked settlement voucher);
everything else is named UNATTRIBUTED and never imputed to an invoice.

The load-bearing test here is TestReconciliationIdentityGate. It is a gate,
not an ordinary test: it proves that a real settlement with no attribution
keeps the GL correct AND does not get converted into a fabricated invoice
allocation. Without it, nothing stops a future change from closing the
reconciliation gap by inventing attribution — which is exactly the defect
Phase 16A measured (31,407g of "remaining" against a 3,446g real position).

Run:
    python -m pytest tests/test_gold_allocation_service.py -v
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import (
    GoldAllocation,
    GoldAttributionBoundary,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    InvoiceGoldObligation,
    Item,
    JournalEntry,
    JournalEntryLine,
    Supplier,
    SupplierGoldAdvance,
    Voucher,
    VoucherAccountLine,
    db,
)
from party_account_service import ensure_supplier_accounts
from pricing.karat_service import convert_to_main_karat
from services.gold_allocation_service import (
    GoldAllocationService,
    advance_remaining,
    create_gold_obligations_for_invoice,
    direct_linked_settlement_for_invoice,
    is_gold_obligation_eligible,
    obligation_attributed_remaining,
    obligation_attributed_settlement,
    reconcile_supplier,
    reverse_gold_allocations_for_invoice,
    sync_gold_advance_after_voucher_approval,
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

    # Production gets this row from migration 20260924_voucher_invoice_gold_attr;
    # a create_all() test database has to seed it, because
    # historical_attribution_boundary() fails CLOSED at 0 — deriving nothing
    # rather than risking a stale answer. Seeded high so every voucher a test
    # creates counts as historical, which is what the derived-path tests mean.
    if GoldAttributionBoundary.query.first() is None:
        db.session.add(GoldAttributionBoundary(max_historical_voucher_id=10 ** 9))
        db.session.flush()

    yield

    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier(*, with_accounts=False):
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد اختبار {_uid()}')
    db.session.add(s)
    db.session.flush()
    if with_accounts:
        ensure_supplier_accounts(s)
        db.session.flush()
    return s


def _account():
    from models import Account
    a = Account(account_number=f'9{_uid()[:5]}', name=f'حساب اختبار {_uid()}', type='Liability')
    db.session.add(a)
    db.session.flush()
    return a


def _voucher(supplier_id, *, reference_type='gold_advance', reference_id=None, status='approved'):
    v = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=supplier_id, reference_type=reference_type,
        reference_id=reference_id, status=status, created_by='test',
    )
    db.session.add(v)
    db.session.flush()
    return v


def _advance(supplier_id, *, karat=21.0, weight=100.0, created_at=None):
    voucher = _voucher(supplier_id)
    a = SupplierGoldAdvance(
        supplier_id=supplier_id, source_voucher_id=voucher.id,
        karat=karat, weight=weight,
    )
    if created_at:
        a.created_at = created_at
    db.session.add(a)
    db.session.flush()
    return a


def _invoice(supplier_id, *, date=None, invoice_type='شراء', office_id=None):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type=invoice_type,
        supplier_id=supplier_id, date=date or datetime.now(), total=1000.0,
        status='unpaid', amount_paid=0.0, is_posted=True, office_id=office_id,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _obligation(invoice_id, *, karat=21.0, weight=100.0):
    ob = InvoiceGoldObligation(invoice_id=invoice_id, karat=karat, weight=weight)
    db.session.add(ob)
    db.session.flush()
    return ob


def _post_supplier_gold(supplier, *, karat=21, credit=0.0, debit=0.0, voucher=None):
    """Post a real supplier-tagged gold line to the GL.

    credit increases the supplier's gold liability (an invoice obliging us),
    debit reduces it (a payment) — the direction verified empirically in
    Phase 12E. When *voucher* is given the entry is tagged as that voucher's
    own posting, which is what makes a settlement direct-linked.
    """
    accounts = ensure_supplier_accounts(supplier)
    je = JournalEntry(
        entry_number=f'JE-{_uid()}',
        date=datetime.now() - timedelta(days=1),
        description='قيد اختباري',
        entry_type='عادي',
        is_posted=True,
        is_draft=False,
        created_by='test',
        reference_type='voucher' if voucher is not None else None,
        reference_id=voucher.id if voucher is not None else None,
    )
    db.session.add(je)
    db.session.flush()

    line_kwargs = {
        'journal_entry_id': je.id,
        'account_id': accounts.financial.id,
        'supplier_id': supplier.id,
        'description': 'قيد اختباري',
    }
    if credit:
        line_kwargs[f'credit_{karat}k'] = credit
    if debit:
        line_kwargs[f'debit_{karat}k'] = debit
    db.session.add(JournalEntryLine(**line_kwargs))
    db.session.flush()
    return je


# ======================================================================
# THE GATE
# ======================================================================

class TestReconciliationIdentityGate:
    """gross_obligation - attributed_settlement - unattributed_settlement
    == gl_position, in main-karat-equivalent.

    The comparison is in main-karat-equivalent while every stored detail keeps
    its own real karat — Phase 14's rule.
    """

    def test_unattributed_payment_keeps_gl_true_and_invents_no_allocation(self):
        """A real gold payment that names no invoice must (a) be fully
        reflected in the GL position, (b) be reported as UNATTRIBUTED by name,
        and (c) produce no GoldAllocation whatsoever.

        This is the exact shape of the 115 real vouchers Phase 16B found: real
        settlement, zero invoice attribution. The old model had no way to
        express it and so reported the obligation as fully open while the GL
        said otherwise.
        """
        supplier = _supplier(with_accounts=True)
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        # The invoice's own liability, then a generic payment of 40g against it.
        _post_supplier_gold(supplier, karat=21, credit=100.0)
        _post_supplier_gold(supplier, karat=21, debit=40.0)

        rec = reconcile_supplier(supplier)

        assert rec['unit'] == 'main_karat_equivalent'
        assert rec['gross_obligation'] == 100.0
        assert rec['attributed_settlement'] == 0.0, 'nothing is evidenced against the invoice'
        assert rec['gl_position'] == 60.0, 'the GL knows 40g was really paid'
        assert rec['unattributed_settlement'] == 40.0, 'the residual must be NAMED, not hidden'

        # The identity itself.
        assert round(
            rec['gross_obligation'] - rec['attributed_settlement']
            - rec['unattributed_settlement'], 2
        ) == rec['gl_position']

        # (c) nothing was invented to close the gap.
        assert GoldAllocation.query.filter_by(obligation_id=obligation.id).count() == 0

        # The invoice-level figure stays an upper bound, explicitly not "owed".
        assert obligation_attributed_remaining(obligation) == 100.0

    def test_identity_holds_once_attribution_exists(self):
        """With an explicit allocation, the same weight moves from the
        unattributed residual into attributed_settlement — the identity is
        unchanged, only the explanation improves."""
        supplier = _supplier(with_accounts=True)
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=40.0)

        _post_supplier_gold(supplier, karat=21, credit=100.0)
        _post_supplier_gold(supplier, karat=21, debit=40.0)

        GoldAllocationService().allocate(
            advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=40.0,
        )

        rec = reconcile_supplier(supplier)
        assert rec['gross_obligation'] == 100.0
        assert rec['attributed_settlement'] == 40.0
        assert rec['unattributed_settlement'] == 0.0
        assert rec['gl_position'] == 60.0
        assert round(
            rec['gross_obligation'] - rec['attributed_settlement']
            - rec['unattributed_settlement'], 2
        ) == rec['gl_position']

    def test_unallocated_advance_is_reported_without_touching_any_invoice(self):
        supplier = _supplier(with_accounts=True)
        _invoice(supplier.id)
        advance = _advance(supplier.id, karat=21.0, weight=75.0)

        rec = reconcile_supplier(supplier)
        assert rec['unallocated_advances'] == 75.0
        assert rec['attributed_settlement'] == 0.0
        assert GoldAllocation.query.filter_by(advance_id=advance.id).count() == 0


# ======================================================================
# No automatic attribution, anywhere
# ======================================================================

class TestNoAutomaticAttribution:

    def test_creating_obligations_does_not_consume_an_open_advance(self):
        """Phase 15 auto-allocated here. Phase 16C must not: an older advance
        is not evidence that it paid this new invoice."""
        supplier = _supplier()
        advance = _advance(supplier.id, karat=21.0, weight=100.0)
        invoice = _invoice(supplier.id)
        db.session.add(InvoiceKaratLine(invoice_id=invoice.id, karat=21.0, weight_grams=60.0))
        db.session.flush()

        obligations = create_gold_obligations_for_invoice(invoice)

        assert len(obligations) == 1
        assert GoldAllocation.query.filter_by(advance_id=advance.id).count() == 0
        assert advance_remaining(advance) == 100.0
        assert obligation_attributed_remaining(obligations[0]) == 60.0

    def test_advance_creation_does_not_consume_an_open_obligation(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _voucher(supplier.id)
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id, account_id=_account().id, line_type='debit',
            amount_type='gold', amount=40.0, karat=21.0,
        ))
        db.session.flush()

        sync_gold_advance_after_voucher_approval(voucher)

        advance = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).first()
        assert advance is not None, 'the advance itself is still recorded'
        assert GoldAllocation.query.filter_by(advance_id=advance.id).count() == 0, \
            'but it attributes itself to nothing'
        assert advance_remaining(advance) == 40.0
        assert obligation_attributed_remaining(obligation) == 100.0

    def test_service_exposes_no_auto_allocation_api(self):
        svc = GoldAllocationService()
        for removed in ('auto_allocate_for_advance', 'auto_allocate_for_obligation',
                        'build_plan_for_advance', 'build_plan_for_obligation', 'apply_plan'):
            assert not hasattr(svc, removed), f'{removed} must not exist under Phase 16C'


# ======================================================================
# Eligibility gate
# ======================================================================

class TestEligibility:

    def test_office_reservation_invoice_creates_no_obligation(self):
        """Phase 16A: such an invoice posts cash only to the GL, so an
        obligation row would be a phantom (29 existed in a local copy)."""
        supplier = _supplier()
        invoice = _invoice(supplier.id, office_id=7)
        db.session.add(InvoiceKaratLine(invoice_id=invoice.id, karat=21.0, weight_grams=50.0))
        db.session.flush()

        assert is_gold_obligation_eligible(invoice) is False
        assert create_gold_obligations_for_invoice(invoice) == []
        assert InvoiceGoldObligation.query.filter_by(invoice_id=invoice.id).count() == 0

    def test_regular_purchase_invoice_is_eligible(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        assert is_gold_obligation_eligible(invoice) is True

    def test_non_purchase_invoice_is_not_eligible(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id, invoice_type='مرتجع شراء (مورد)')
        assert is_gold_obligation_eligible(invoice) is False
        assert create_gold_obligations_for_invoice(invoice) == []


# ======================================================================
# Derived remaining — the two different kinds
# ======================================================================

class TestAdvanceRemainingIsExact:

    def test_full_weight_when_never_allocated(self):
        supplier = _supplier()
        advance = _advance(supplier.id, karat=21.0, weight=100.0)
        assert advance_remaining(advance) == 100.0

    def test_reduced_by_each_allocation(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)
        svc = GoldAllocationService()

        svc.allocate(advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=30.0)
        assert advance_remaining(advance) == 70.0

        svc.allocate(advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=20.0)
        assert advance_remaining(advance) == 50.0

    def test_converted_to_main_karat(self):
        supplier = _supplier()
        advance = _advance(supplier.id, karat=18.0, weight=100.0)
        assert advance_remaining(advance) == round(convert_to_main_karat(100.0, 18.0), 2)

    def test_restored_by_unallocate(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)
        svc = GoldAllocationService()
        svc.allocate(advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=40.0)

        assert svc.unallocate(advance_id=advance.id) == 1
        assert advance_remaining(advance) == 100.0


class TestObligationAttributedRemaining:

    def test_full_gross_when_nothing_is_evidenced(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        assert obligation_attributed_settlement(obligation) == 0.0
        assert obligation_attributed_remaining(obligation) == 100.0

    def test_reduced_by_an_explicit_allocation(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)
        GoldAllocationService().allocate(
            advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=25.0,
        )
        assert obligation_attributed_remaining(obligation) == 75.0

    def test_reduced_by_a_direct_linked_settlement_voucher(self):
        """Phase 12E mechanism A: a voucher naming this invoice IS evidence,
        and is derived from the GL rather than stored in a table of its own."""
        supplier = _supplier(with_accounts=True)
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _voucher(supplier.id, reference_type='invoice', reference_id=invoice.id)
        _post_supplier_gold(supplier, karat=21, debit=30.0, voucher=voucher)

        assert direct_linked_settlement_for_invoice(invoice.id) == 30.0
        assert obligation_attributed_settlement(obligation) == 30.0
        assert obligation_attributed_remaining(obligation) == 70.0

    def test_direct_linked_settlement_in_a_karat_the_invoice_never_had(self):
        """Phase 16A found 8 of 34 real mechanism-A vouchers settle a karat the
        invoice never contained (invoice 52: all items 21k, voucher settled
        18k). Same-karat matching would miss them entirely, so the settlement
        is netted in main-karat-equivalent instead."""
        supplier = _supplier(with_accounts=True)
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _voucher(supplier.id, reference_type='invoice', reference_id=invoice.id)
        _post_supplier_gold(supplier, karat=18, debit=30.0, voucher=voucher)

        expected = round(convert_to_main_karat(30.0, 18), 2)
        assert direct_linked_settlement_for_invoice(invoice.id) == expected
        assert obligation_attributed_settlement(obligation) == expected

    def test_direct_linked_settlement_splits_across_the_invoices_karats(self):
        """reference_id proves the INVOICE, not a karat — so the evidence is
        shared proportionally rather than assigned to one karat row."""
        supplier = _supplier(with_accounts=True)
        invoice = _invoice(supplier.id)
        ob_21 = _obligation(invoice.id, karat=21.0, weight=75.0)
        ob_18 = _obligation(invoice.id, karat=18.0, weight=100.0)

        voucher = _voucher(supplier.id, reference_type='invoice', reference_id=invoice.id)
        _post_supplier_gold(supplier, karat=21, debit=40.0, voucher=voucher)

        gross_21 = convert_to_main_karat(75.0, 21.0)
        gross_18 = convert_to_main_karat(100.0, 18.0)
        total = gross_21 + gross_18
        assert obligation_attributed_settlement(ob_21) == round(40.0 * gross_21 / total, 2)
        assert obligation_attributed_settlement(ob_18) == round(40.0 * gross_18 / total, 2)

    def test_an_unapproved_settlement_voucher_is_not_evidence(self):
        supplier = _supplier(with_accounts=True)
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _voucher(
            supplier.id, reference_type='invoice', reference_id=invoice.id, status='pending',
        )
        _post_supplier_gold(supplier, karat=21, debit=30.0, voucher=voucher)

        assert direct_linked_settlement_for_invoice(invoice.id) == 0.0
        assert obligation_attributed_remaining(obligation) == 100.0

    def test_never_reports_negative_remaining(self):
        supplier = _supplier(with_accounts=True)
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=50.0)

        voucher = _voucher(supplier.id, reference_type='invoice', reference_id=invoice.id)
        _post_supplier_gold(supplier, karat=21, debit=500.0, voucher=voucher)

        assert obligation_attributed_remaining(obligation) == 0.0


# ======================================================================
# allocate() — the only writer
# ======================================================================

class TestAllocate:

    def test_writes_one_row_and_reports_both_sides(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=60.0)

        allocation = GoldAllocationService().allocate(
            advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=25.0,
        )

        assert allocation.id is not None
        assert allocation.weight_applied_main_karat == 25.0
        assert advance_remaining(advance) == 35.0
        assert obligation_attributed_remaining(obligation) == 75.0

    def test_rejects_more_than_the_advance_has(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=30.0)

        with pytest.raises(ValueError, match='exceeds_advance_remaining'):
            GoldAllocationService().allocate(
                advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=40.0,
            )

    def test_rejects_more_than_the_obligation_can_evidence(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=20.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)

        with pytest.raises(ValueError, match='exceeds_invoice_obligation_remaining'):
            GoldAllocationService().allocate(
                advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=50.0,
            )

    def test_rejects_crossing_suppliers(self):
        supplier_a = _supplier()
        supplier_b = _supplier()
        invoice_b = _invoice(supplier_b.id)
        obligation_b = _obligation(invoice_b.id, karat=21.0, weight=100.0)
        advance_a = _advance(supplier_a.id, karat=21.0, weight=100.0)

        with pytest.raises(ValueError, match='supplier_mismatch'):
            GoldAllocationService().allocate(
                advance_id=advance_a.id, obligation_id=obligation_b.id, weight_main_karat=10.0,
            )

    def test_rejects_non_positive_weight(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)

        with pytest.raises(ValueError, match='weight_main_karat_must_be_positive'):
            GoldAllocationService().allocate(
                advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=0.0,
            )

    def test_allows_cross_karat_because_a_human_decided_it(self):
        """Both sides are compared in main-karat-equivalent, mirroring the real
        karat_diff_* mechanism where a human specifies a cross-karat
        settlement. What is forbidden is inventing the decision, not making
        it."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation_18 = _obligation(invoice.id, karat=18.0, weight=100.0)
        advance_21 = _advance(supplier.id, karat=21.0, weight=50.0)

        allocation = GoldAllocationService().allocate(
            advance_id=advance_21.id, obligation_id=obligation_18.id, weight_main_karat=20.0,
        )
        assert allocation.id is not None
        assert advance_remaining(advance_21) == 30.0

    def test_rejects_unknown_ids(self):
        svc = GoldAllocationService()
        with pytest.raises(ValueError, match='gold_advance_not_found'):
            svc.allocate(advance_id=99999999, obligation_id=1, weight_main_karat=1.0)

        supplier = _supplier()
        advance = _advance(supplier.id)
        with pytest.raises(ValueError, match='invoice_gold_obligation_not_found'):
            svc.allocate(advance_id=advance.id, obligation_id=99999999, weight_main_karat=1.0)


class TestUnallocate:

    def test_requires_a_filter(self):
        with pytest.raises(ValueError, match='unallocate_requires_at_least_one_filter'):
            GoldAllocationService().unallocate()

    def test_deletes_rows_and_restores_derived_values(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)
        svc = GoldAllocationService()
        svc.allocate(advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=40.0)

        assert svc.unallocate(obligation_id=obligation.id) == 1
        assert GoldAllocation.query.filter_by(obligation_id=obligation.id).count() == 0
        assert advance_remaining(advance) == 100.0
        assert obligation_attributed_remaining(obligation) == 100.0

    def test_is_a_noop_when_nothing_is_allocated(self):
        supplier = _supplier()
        advance = _advance(supplier.id)
        assert GoldAllocationService().unallocate(advance_id=advance.id) == 0


# ======================================================================
# create_gold_obligations_for_invoice — the normalizer, now attribution-free
# ======================================================================

class TestCreateGoldObligationsForInvoice:

    def test_uses_karat_lines_when_present(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        db.session.add_all([
            InvoiceKaratLine(invoice_id=invoice.id, karat=21.0, weight_grams=40.0),
            InvoiceKaratLine(invoice_id=invoice.id, karat=21.0, weight_grams=10.0),
            InvoiceKaratLine(invoice_id=invoice.id, karat=18.0, weight_grams=25.0),
        ])
        db.session.flush()

        obligations = create_gold_obligations_for_invoice(invoice)

        by_karat = {ob.karat: ob.weight for ob in obligations}
        assert by_karat == {21.0: 50.0, 18.0: 25.0}

    def test_falls_back_to_items_multiplying_quantity(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        db.session.add_all([
            InvoiceItem(invoice_id=invoice.id, karat=21.0, weight=10.0, quantity=3, price=0.0),
            InvoiceItem(invoice_id=invoice.id, karat=21.0, weight=5.0, quantity=1, price=0.0),
        ])
        db.session.flush()

        obligations = create_gold_obligations_for_invoice(invoice)

        assert len(obligations) == 1
        assert obligations[0].karat == 21.0
        assert obligations[0].weight == 35.0

    def test_item_fallback_reads_the_linked_items_karat_and_weight(self):
        supplier = _supplier()
        item = Item(
            item_code=f'ITM-{_uid()}', name='صنف اختبار', karat=18.0, weight=12.0, price=0.0,
        )
        db.session.add(item)
        db.session.flush()

        invoice = _invoice(supplier.id)
        db.session.add(InvoiceItem(invoice_id=invoice.id, item_id=item.id, quantity=2, price=0.0))
        db.session.flush()

        obligations = create_gold_obligations_for_invoice(invoice)

        assert len(obligations) == 1
        assert obligations[0].karat == 18.0
        assert obligations[0].weight == 24.0

    def test_karat_lines_take_priority_over_items(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        db.session.add_all([
            InvoiceKaratLine(invoice_id=invoice.id, karat=21.0, weight_grams=100.0),
            InvoiceItem(invoice_id=invoice.id, karat=21.0, weight=100.0, quantity=1, price=0.0),
        ])
        db.session.flush()

        obligations = create_gold_obligations_for_invoice(invoice)

        assert len(obligations) == 1
        assert obligations[0].weight == 100.0, 'must not double-count the same fact'

    def test_is_idempotent(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        db.session.add(InvoiceKaratLine(invoice_id=invoice.id, karat=21.0, weight_grams=40.0))
        db.session.flush()

        first = create_gold_obligations_for_invoice(invoice)
        second = create_gold_obligations_for_invoice(invoice)

        assert len(first) == 1
        assert second == []
        assert InvoiceGoldObligation.query.filter_by(invoice_id=invoice.id).count() == 1

    def test_skips_zero_and_negative_weight(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        db.session.add_all([
            InvoiceKaratLine(invoice_id=invoice.id, karat=21.0, weight_grams=0.0),
            InvoiceKaratLine(invoice_id=invoice.id, karat=18.0, weight_grams=30.0),
        ])
        db.session.flush()

        obligations = create_gold_obligations_for_invoice(invoice)
        assert [ob.karat for ob in obligations] == [18.0]


# ======================================================================
# sync_gold_advance_after_voucher_approval
# ======================================================================

class TestSyncGoldAdvanceAfterVoucherApproval:

    def _gold_voucher(self, supplier_id, lines):
        voucher = _voucher(supplier_id)
        for karat, amount in lines:
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id, account_id=_account().id, line_type='debit',
                amount_type='gold', amount=amount, karat=karat,
            ))
        db.session.flush()
        return voucher

    def test_creates_one_advance_per_karat(self):
        supplier = _supplier()
        voucher = self._gold_voucher(supplier.id, [(21.0, 50.0), (18.0, 30.0)])

        sync_gold_advance_after_voucher_approval(voucher)

        advances = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).all()
        assert {a.karat: a.weight for a in advances} == {21.0: 50.0, 18.0: 30.0}

    def test_is_idempotent(self):
        supplier = _supplier()
        voucher = self._gold_voucher(supplier.id, [(21.0, 50.0)])

        sync_gold_advance_after_voucher_approval(voucher)
        sync_gold_advance_after_voucher_approval(voucher)

        assert SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).count() == 1

    def test_ignores_a_non_gold_advance_voucher(self):
        """The 115 real historical manual payment vouchers carry
        reference_type=None. They must never be silently reinterpreted as
        advances — Phase 16B proved they are supplier-level settlements whose
        invoice attribution is unknown."""
        supplier = _supplier()
        voucher = _voucher(supplier.id, reference_type=None)
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id, account_id=_account().id, line_type='debit',
            amount_type='gold', amount=90.0, karat=21.0,
        ))
        db.session.flush()

        sync_gold_advance_after_voucher_approval(voucher)

        assert SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).count() == 0

    def test_ignores_credit_side_gold_lines(self):
        supplier = _supplier()
        voucher = _voucher(supplier.id)
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id, account_id=_account().id, line_type='credit',
            amount_type='gold', amount=50.0, karat=21.0,
        ))
        db.session.flush()

        sync_gold_advance_after_voucher_approval(voucher)

        assert SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).count() == 0


# ======================================================================
# reverse_gold_allocations_for_invoice
# ======================================================================

class TestReverseGoldAllocationsForInvoice:

    def test_frees_allocations_but_keeps_the_original_obligation(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)
        GoldAllocationService().allocate(
            advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=40.0,
        )

        freed = reverse_gold_allocations_for_invoice(invoice.id)

        assert freed == 1
        assert advance_remaining(advance) == 100.0
        assert InvoiceGoldObligation.query.get(obligation.id) is not None, \
            'the original obligation remains historically true'

    def test_is_a_noop_for_an_invoice_with_no_obligations(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        assert reverse_gold_allocations_for_invoice(invoice.id) == 0
