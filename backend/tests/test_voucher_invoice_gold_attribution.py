"""Phase A — attribution is recorded, never inferred, and never double-counted.

Two sources can speak about an invoice's gold: rows a person recorded, and the
bounded historical derivation from `Voucher.reference_type='invoice'` plus the
GL. The load-bearing tests here are the ones proving they are ONE answer
(TestNoDoubleCounting) and that one obligation is ONE budget shared by advance
allocations and attributions (TestSharedCeiling) — get either wrong and an
invoice "settles" twice over.

Run:
    python -m pytest tests/test_voucher_invoice_gold_attribution.py -v
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import (
    Account,
    GoldAllocation,
    GoldAttributionBoundary,
    Invoice,
    InvoiceGoldObligation,
    JournalEntry,
    JournalEntryLine,
    Supplier,
    SupplierGoldAdvance,
    Voucher,
    VoucherAccountLine,
    VoucherInvoiceGoldAttribution,
    db,
)
from party_account_service import ensure_supplier_accounts
from pricing.karat_service import convert_to_main_karat
from services.gold_allocation_service import (
    GoldAllocationService,
    attribute_gold_to_invoice,
    direct_linked_settlement_for_invoice,
    historical_attribution_boundary,
    invoice_open_gold_obligation,
    obligation_attributed_remaining,
    recorded_attribution_for_invoice,
    remove_attributions_for_voucher,
    sync_gold_attribution_after_voucher_approval,
)

BOUNDARY = 10 ** 9


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

    if GoldAttributionBoundary.query.first() is None:
        db.session.add(GoldAttributionBoundary(max_historical_voucher_id=BOUNDARY))
        db.session.flush()

    yield

    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


def _uid():
    return uuid.uuid4().hex[:8]


def _account():
    a = Account(account_number=f'9{_uid()[:5]}', name=f'حساب {_uid()}', type='Liability')
    db.session.add(a)
    db.session.flush()
    return a


def _supplier():
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


def _invoice(supplier_id):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
        supplier_id=supplier_id, date=datetime.now(), total=1000.0,
        status='unpaid', amount_paid=0.0, is_posted=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _obligation(invoice_id, *, karat=21.0, weight=100.0):
    ob = InvoiceGoldObligation(invoice_id=invoice_id, karat=karat, weight=weight)
    db.session.add(ob)
    db.session.flush()
    return ob


def _gold_voucher(supplier_id, *, lines, reference_type='invoice', reference_id=None,
                  status='approved'):
    """A voucher carrying gold DEBIT lines — the shape both Mechanism A and an
    employee's explicit invoice payment produce. *lines* is [(karat, weight)]."""
    v = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=supplier_id,
        reference_type=reference_type, reference_id=reference_id,
        status=status, created_by='tester',
    )
    db.session.add(v)
    db.session.flush()
    for karat, weight in lines:
        db.session.add(VoucherAccountLine(
            voucher_id=v.id, account_id=_account().id, line_type='debit',
            amount_type='gold', amount=weight, karat=karat,
        ))
    db.session.flush()
    return v


def _post_supplier_gold_debit(supplier, voucher, *, karat=21, weight=30.0):
    """The GL side of a settlement, tagged to the voucher — what the historical
    derivation reads."""
    accounts = ensure_supplier_accounts(supplier)
    je = JournalEntry(
        entry_number=f'JE-{_uid()}', date=datetime.now() - timedelta(days=1),
        description='قيد', entry_type='عادي', is_posted=True, is_draft=False,
        created_by='test', reference_type='voucher', reference_id=voucher.id,
    )
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(**{
        'journal_entry_id': je.id, 'account_id': accounts.financial.id,
        'supplier_id': supplier.id, 'description': 'قيد', f'debit_{karat}k': weight,
    }))
    db.session.flush()
    return je


# ======================================================================
# The boundary
# ======================================================================

class TestBoundary:

    def test_is_read_from_data_not_recomputed(self):
        assert historical_attribution_boundary() == BOUNDARY

    def test_a_voucher_above_the_boundary_is_never_derived(self):
        """Above the line, only recorded rows count — this is what stops the
        'two answers' problem from reopening."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=100.0)

        GoldAttributionBoundary.query.first().max_historical_voucher_id = 0
        db.session.flush()

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 30.0)], reference_id=invoice.id)
        _post_supplier_gold_debit(supplier, voucher, karat=21, weight=30.0)

        assert direct_linked_settlement_for_invoice(invoice.id) == 0.0

    def test_missing_boundary_row_fails_closed(self):
        """No boundary means derive nothing — understating settlement is the
        safe direction, overstating it is not."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=100.0)
        voucher = _gold_voucher(supplier.id, lines=[(21.0, 30.0)], reference_id=invoice.id)
        _post_supplier_gold_debit(supplier, supplier and voucher, karat=21, weight=30.0)

        for row in GoldAttributionBoundary.query.all():
            db.session.delete(row)
        db.session.flush()

        assert historical_attribution_boundary() == 0
        assert direct_linked_settlement_for_invoice(invoice.id) == 0.0


# ======================================================================
# THE GATE: one answer, never two
# ======================================================================

class TestNoDoubleCounting:

    def test_a_voucher_with_recorded_rows_is_not_also_derived(self):
        """The precise anti-double-count rule: a voucher below the boundary that
        has been given explicit rows is read from its rows ONLY. Without this a
        30g payment would settle 60g of obligation."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 30.0)], reference_id=invoice.id)
        _post_supplier_gold_debit(supplier, voucher, karat=21, weight=30.0)

        # Derived only, before any row exists.
        assert direct_linked_settlement_for_invoice(invoice.id) == 30.0

        attribute_gold_to_invoice(
            voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=30.0,
        )

        assert recorded_attribution_for_invoice(invoice.id) == 30.0
        assert direct_linked_settlement_for_invoice(invoice.id) == 30.0, \
            'the same payment must not be counted twice'

    def test_recorded_and_derived_from_different_vouchers_both_count(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=100.0)

        historical = _gold_voucher(supplier.id, lines=[(21.0, 20.0)], reference_id=invoice.id)
        _post_supplier_gold_debit(supplier, historical, karat=21, weight=20.0)

        explicit = _gold_voucher(supplier.id, lines=[(21.0, 25.0)], reference_id=invoice.id)
        attribute_gold_to_invoice(
            voucher=explicit, invoice_id=invoice.id, karat=21.0, weight=25.0,
        )

        assert direct_linked_settlement_for_invoice(invoice.id) == 45.0


# ======================================================================
# THE GATE: one obligation is one budget
# ======================================================================

class TestSharedCeiling:

    def test_an_advance_allocation_reduces_what_attribution_may_claim(self):
        """60g of advance plus 60g of attribution must not settle a 100g
        obligation."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        advance_voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 60.0)], reference_type='gold_advance',
        )
        advance = SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=advance_voucher.id,
            karat=21.0, weight=60.0,
        )
        db.session.add(advance)
        db.session.flush()
        GoldAllocationService().allocate(
            advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=60.0,
        )

        assert invoice_open_gold_obligation(invoice.id) == 40.0

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 60.0)], reference_id=invoice.id)
        with pytest.raises(ValueError, match='exceeds_invoice_obligation_remaining'):
            attribute_gold_to_invoice(
                voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=60.0,
            )

    def test_attribution_reduces_what_an_advance_may_allocate(self):
        """The mirror direction — the budget is shared both ways."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 70.0)], reference_id=invoice.id)
        attribute_gold_to_invoice(
            voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=70.0,
        )
        assert obligation_attributed_remaining(obligation) == 30.0

        advance_voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 50.0)], reference_type='gold_advance',
        )
        advance = SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=advance_voucher.id,
            karat=21.0, weight=50.0,
        )
        db.session.add(advance)
        db.session.flush()

        with pytest.raises(ValueError, match='exceeds_invoice_obligation_remaining'):
            GoldAllocationService().allocate(
                advance_id=advance.id, obligation_id=obligation.id, weight_main_karat=50.0,
            )

    def test_cannot_attribute_more_than_the_voucher_carries(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=500.0)

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 30.0)], reference_id=invoice.id)
        with pytest.raises(ValueError, match='exceeds_voucher_gold'):
            attribute_gold_to_invoice(
                voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=40.0,
            )


# ======================================================================
# The real karat survives
# ======================================================================

class TestKaratIsPreserved:

    def test_stores_the_actual_karat_paid_and_the_equivalent_separately(self):
        """Phase 16A found 8 of 34 real settlements paid a karat the invoice
        never contained. '18k against a 21k obligation' must stay a fact."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _gold_voucher(supplier.id, lines=[(18.0, 30.0)], reference_id=invoice.id)
        row = attribute_gold_to_invoice(
            voucher=voucher, invoice_id=invoice.id, karat=18.0, weight=30.0,
        )

        assert row.karat == 18.0
        assert row.weight == 30.0
        assert row.weight_main_karat == round(convert_to_main_karat(30.0, 18.0), 2)
        assert row.weight_main_karat != row.weight, \
            'the equivalent is for balancing; it must not overwrite the real weight'


# ======================================================================
# Lifecycle
# ======================================================================

class TestApprovalWritesAttribution:

    def test_creates_one_row_per_karat_from_the_vouchers_own_lines(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=500.0)

        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 40.0), (18.0, 20.0)], reference_id=invoice.id,
        )
        created = sync_gold_attribution_after_voucher_approval(voucher)

        assert created == 2
        rows = VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).all()
        assert {r.karat: r.weight for r in rows} == {21.0: 40.0, 18.0: 20.0}

    def test_is_idempotent(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=500.0)
        voucher = _gold_voucher(supplier.id, lines=[(21.0, 40.0)], reference_id=invoice.id)

        assert sync_gold_attribution_after_voucher_approval(voucher) == 1
        assert sync_gold_attribution_after_voucher_approval(voucher) == 0
        assert VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).count() == 1

    def test_an_unapproved_voucher_gets_no_attribution(self):
        """No attribution without an approved payment behind it."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=500.0)
        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 40.0)], reference_id=invoice.id, status='pending',
        )

        assert sync_gold_attribution_after_voucher_approval(voucher) == 0
        with pytest.raises(ValueError, match='voucher_not_approved'):
            attribute_gold_to_invoice(
                voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=10.0,
            )

    def test_a_general_supplier_settlement_attributes_nothing(self):
        """The third classifier option is a legitimate business case, not a
        fallback: it must record no invoice attribution at all."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=500.0)

        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 40.0)], reference_type='gold_supplier',
        )
        assert sync_gold_attribution_after_voucher_approval(voucher) == 0
        assert recorded_attribution_for_invoice(invoice.id) == 0.0

    def test_an_advance_attributes_nothing(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=500.0)
        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 40.0)], reference_type='gold_advance',
        )
        assert sync_gold_attribution_after_voucher_approval(voucher) == 0

    def test_rejects_an_invoice_belonging_to_another_supplier(self):
        supplier_a = _supplier()
        supplier_b = _supplier()
        invoice_b = _invoice(supplier_b.id)
        _obligation(invoice_b.id, karat=21.0, weight=500.0)

        voucher = _gold_voucher(supplier_a.id, lines=[(21.0, 10.0)], reference_id=invoice_b.id)
        with pytest.raises(ValueError, match='supplier_mismatch'):
            attribute_gold_to_invoice(
                voucher=voucher, invoice_id=invoice_b.id, karat=21.0, weight=10.0,
            )


class TestCancellationRemovesAttribution:

    def test_removing_a_vouchers_attribution_frees_the_obligation(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 40.0)], reference_id=invoice.id)
        attribute_gold_to_invoice(
            voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=40.0,
        )
        assert obligation_attributed_remaining(obligation) == 60.0

        assert remove_attributions_for_voucher(voucher.id) == 1
        assert obligation_attributed_remaining(obligation) == 100.0

    def test_is_a_noop_for_a_voucher_with_no_attribution(self):
        supplier = _supplier()
        voucher = _gold_voucher(supplier.id, lines=[(21.0, 10.0)], reference_type='gold_supplier')
        assert remove_attributions_for_voucher(voucher.id) == 0


# ======================================================================
# No inference, ever
# ======================================================================

class TestNoInference:

    def test_nothing_attributes_itself_when_an_obligation_is_open(self):
        """A supplier with an open obligation and an approved gold payment that
        names no invoice must end up with zero attribution — the 81% case."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 100.0)], reference_type='gold_supplier',
        )
        sync_gold_attribution_after_voucher_approval(voucher)

        assert recorded_attribution_for_invoice(invoice.id) == 0.0
        assert obligation_attributed_remaining(obligation) == 100.0
        assert GoldAllocation.query.filter_by(obligation_id=obligation.id).count() == 0


# ======================================================================
# Correcting a classification after the fact
# ======================================================================

class TestCorrectingAClassification:
    """A payment declared a general supplier settlement records no attribution,
    which is correct — but until this path existed the invoice had no way back:
    its gold side stayed unsettled even when the amount matched the obligation
    exactly. The capability was always in the service; it had no route."""

    def test_a_general_settlement_can_be_reattributed_later(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)

        # Declared as a general settlement: no attribution, invoice untouched.
        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 100.0)], reference_type='gold_supplier',
        )
        sync_gold_attribution_after_voucher_approval(voucher)
        assert obligation_attributed_remaining(obligation) == 100.0

        # Someone realises it was for this invoice and says so.
        attribute_gold_to_invoice(
            voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=100.0,
        )

        assert obligation_attributed_remaining(obligation) == 0.0
        assert recorded_attribution_for_invoice(invoice.id) == 100.0

    def test_a_correction_cannot_exceed_what_the_voucher_carries(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=500.0)
        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 40.0)], reference_type='gold_supplier',
        )

        with pytest.raises(ValueError, match='exceeds_voucher_gold'):
            attribute_gold_to_invoice(
                voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=60.0,
            )

    def test_a_correction_can_be_undone_and_frees_the_obligation(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id, karat=21.0, weight=100.0)
        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 60.0)], reference_type='gold_supplier',
        )
        row = attribute_gold_to_invoice(
            voucher=voucher, invoice_id=invoice.id, karat=21.0, weight=60.0,
        )
        assert obligation_attributed_remaining(obligation) == 40.0

        db.session.delete(row)
        db.session.flush()

        assert obligation_attributed_remaining(obligation) == 100.0

    def test_correcting_twice_respects_the_shared_ceiling(self):
        """Two corrections against the same invoice draw from one budget."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=100.0)

        first = _gold_voucher(
            supplier.id, lines=[(21.0, 70.0)], reference_type='gold_supplier',
        )
        attribute_gold_to_invoice(
            voucher=first, invoice_id=invoice.id, karat=21.0, weight=70.0,
        )

        second = _gold_voucher(
            supplier.id, lines=[(21.0, 70.0)], reference_type='gold_supplier',
        )
        with pytest.raises(ValueError, match='exceeds_invoice_obligation_remaining'):
            attribute_gold_to_invoice(
                voucher=second, invoice_id=invoice.id, karat=21.0, weight=70.0,
            )


# ======================================================================
# One payment, several invoices
# ======================================================================

class TestSplitAcrossInvoices:
    """Phase 11 found this is the common real shape, not an edge case: a single
    voucher described as «سداد متبقيات سابقة بمبلغ ٤٧٢٥ + باقي قيمة حجز»,
    covering more than one thing deliberately. reference_id is one integer and
    cannot say it."""

    def test_splits_across_two_invoices(self):
        from services.gold_allocation_service import attribute_gold_across_invoices

        supplier = _supplier()
        inv_a = _invoice(supplier.id)
        inv_b = _invoice(supplier.id)
        ob_a = _obligation(inv_a.id, karat=21.0, weight=60.0)
        ob_b = _obligation(inv_b.id, karat=21.0, weight=60.0)

        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 100.0)], reference_type='gold_supplier',
        )
        rows = attribute_gold_across_invoices(voucher=voucher, splits=[
            {'invoice_id': inv_a.id, 'karat': 21.0, 'weight': 60.0},
            {'invoice_id': inv_b.id, 'karat': 21.0, 'weight': 40.0},
        ])

        assert len(rows) == 2
        assert obligation_attributed_remaining(ob_a) == 0.0
        assert obligation_attributed_remaining(ob_b) == 20.0

    def test_a_distribution_exceeding_the_voucher_is_rejected_entirely(self):
        """All or nothing: a half-applied distribution would report part of a
        payment as attributed and leave the rest invisible."""
        from services.gold_allocation_service import attribute_gold_across_invoices

        supplier = _supplier()
        inv_a = _invoice(supplier.id)
        inv_b = _invoice(supplier.id)
        _obligation(inv_a.id, karat=21.0, weight=100.0)
        _obligation(inv_b.id, karat=21.0, weight=100.0)

        voucher = _gold_voucher(
            supplier.id, lines=[(21.0, 100.0)], reference_type='gold_supplier',
        )
        with pytest.raises(ValueError, match='exceeds_voucher_gold'):
            attribute_gold_across_invoices(voucher=voucher, splits=[
                {'invoice_id': inv_a.id, 'karat': 21.0, 'weight': 60.0},
                {'invoice_id': inv_b.id, 'karat': 21.0, 'weight': 60.0},
            ])

    def test_a_declared_distribution_in_notes_is_used_at_approval(self):
        import json

        supplier = _supplier()
        inv_a = _invoice(supplier.id)
        inv_b = _invoice(supplier.id)
        ob_a = _obligation(inv_a.id, karat=21.0, weight=50.0)
        ob_b = _obligation(inv_b.id, karat=21.0, weight=50.0)

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 80.0)], reference_id=inv_a.id)
        voucher.notes = json.dumps({'gold_invoice_splits': [
            {'invoice_id': inv_a.id, 'karat': 21.0, 'weight': 50.0},
            {'invoice_id': inv_b.id, 'karat': 21.0, 'weight': 30.0},
        ]})
        db.session.flush()

        created = sync_gold_attribution_after_voucher_approval(voucher)

        assert created == 2, 'the declared distribution wins over reference_id'
        assert obligation_attributed_remaining(ob_a) == 0.0
        assert obligation_attributed_remaining(ob_b) == 20.0

    def test_malformed_notes_mean_no_declaration_not_a_guess(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        ob = _obligation(invoice.id, karat=21.0, weight=100.0)

        voucher = _gold_voucher(supplier.id, lines=[(21.0, 40.0)], reference_id=invoice.id)
        voucher.notes = 'ملاحظة حرة ليست JSON'
        db.session.flush()

        created = sync_gold_attribution_after_voucher_approval(voucher)

        assert created == 1, 'falls back to reference_id, never to a guess'
        assert obligation_attributed_remaining(ob) == 60.0
