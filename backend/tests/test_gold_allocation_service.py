"""Phase 15B/15A-Correction/15D — GoldAllocationService: the matching/
bookkeeping engine, create_gold_obligations_for_invoice: the InvoiceKaratLine/
InvoiceItem -> InvoiceGoldObligation normalizer, sync_gold_advance_after_
voucher_approval: the Advance side of the trigger, and
reverse_gold_allocations_for_invoice: the reversal mechanism.

Scope, deliberately narrow (see the Phase 15 sub-phase plan in project
memory): the service and its module-level functions, called directly — no
routes (see test_gold_advance_allocation_integration.py for the HTTP-level
proof), no karat-mismatch cash fee (explicitly out of scope for the AUTO
path — see the service's own docstring; test_allows_cross_karat_unlike_
auto_allocation proves the override path deliberately does not share that
restriction).
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import (
    GoldAllocation,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    InvoiceGoldObligation,
    Item,
    Supplier,
    SupplierGoldAdvance,
    Voucher,
    VoucherAccountLine,
    db,
)
from services.gold_allocation_service import (
    GoldAllocationService,
    create_gold_obligations_for_invoice,
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

    yield

    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier():
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد اختبار {_uid()}')
    db.session.add(s)
    db.session.flush()
    return s


def _voucher(supplier_id):
    v = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=supplier_id, reference_type='gold_advance',
        status='approved', created_by='test',
    )
    db.session.add(v)
    db.session.flush()
    return v


def _advance(supplier_id, *, karat=21.0, weight=100.0, remaining=None, created_at=None):
    voucher = _voucher(supplier_id)
    a = SupplierGoldAdvance(
        supplier_id=supplier_id, source_voucher_id=voucher.id,
        karat=karat, weight=weight,
        weight_remaining_main_karat=remaining if remaining is not None else weight,
    )
    if created_at:
        a.created_at = created_at
    db.session.add(a)
    db.session.flush()
    return a


def _invoice(supplier_id, *, date=None):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
        supplier_id=supplier_id, date=date or datetime.now(), total=1000.0,
        status='unpaid', amount_paid=0.0, is_posted=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _obligation(invoice_id, *, karat=21.0, weight=100.0, remaining=None):
    ob = InvoiceGoldObligation(
        invoice_id=invoice_id, karat=karat, weight=weight,
        weight_remaining_main_karat=remaining if remaining is not None else weight,
    )
    db.session.add(ob)
    db.session.flush()
    return ob


class TestAutoAllocateForAdvance:

    def test_fifo_covers_older_invoice_first_then_spills_to_newer(self):
        supplier = _supplier()
        older = _invoice(supplier.id, date=datetime(2026, 1, 1))
        newer = _invoice(supplier.id, date=datetime(2026, 6, 1))
        older_ob = _obligation(older.id, karat=21.0, weight=30.0)
        newer_ob = _obligation(newer.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=50.0)

        plan = GoldAllocationService().auto_allocate_for_advance(advance)
        db.session.commit()

        assert plan.total_allocated == 50.0
        assert plan.unallocated_remainder == 0.0
        assert InvoiceGoldObligation.query.get(older_ob.id).weight_remaining_main_karat == 0.0
        assert InvoiceGoldObligation.query.get(newer_ob.id).weight_remaining_main_karat == 80.0
        assert SupplierGoldAdvance.query.get(advance.id).weight_remaining_main_karat == 0.0

        rows = GoldAllocation.query.filter_by(advance_id=advance.id).order_by(GoldAllocation.id).all()
        assert [r.obligation_id for r in rows] == [older_ob.id, newer_ob.id]
        assert [r.weight_applied_main_karat for r in rows] == [30.0, 20.0]

    def test_advance_smaller_than_single_obligation_leaves_it_open(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=40.0)

        plan = GoldAllocationService().auto_allocate_for_advance(advance)
        db.session.commit()

        assert plan.total_allocated == 40.0
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 60.0
        assert SupplierGoldAdvance.query.get(advance.id).weight_remaining_main_karat == 0.0

    def test_advance_exceeding_all_open_obligations_leaves_unallocated_remainder(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        _obligation(inv.id, karat=21.0, weight=30.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)

        plan = GoldAllocationService().auto_allocate_for_advance(advance)
        db.session.commit()

        assert plan.total_allocated == 30.0
        assert plan.unallocated_remainder == 70.0
        assert SupplierGoldAdvance.query.get(advance.id).weight_remaining_main_karat == 70.0

    def test_different_karat_obligation_is_never_touched(self):
        """Same supplier, different real karat — the deliberate Phase 15B
        boundary (no auto karat-diff bridging) must leave this untouched."""
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob_18k = _obligation(inv.id, karat=18.0, weight=100.0)
        advance_21k = _advance(supplier.id, karat=21.0, weight=50.0)

        plan = GoldAllocationService().auto_allocate_for_advance(advance_21k)
        db.session.commit()

        assert plan.lines == []
        assert plan.unallocated_remainder == 50.0
        assert InvoiceGoldObligation.query.get(ob_18k.id).weight_remaining_main_karat == 100.0
        assert SupplierGoldAdvance.query.get(advance_21k.id).weight_remaining_main_karat == 50.0

    def test_different_supplier_obligation_is_never_touched(self):
        supplier_a = _supplier()
        supplier_b = _supplier()
        inv_b = _invoice(supplier_b.id)
        ob_b = _obligation(inv_b.id, karat=21.0, weight=100.0)
        advance_a = _advance(supplier_a.id, karat=21.0, weight=50.0)

        plan = GoldAllocationService().auto_allocate_for_advance(advance_a)
        db.session.commit()

        assert plan.lines == []
        assert InvoiceGoldObligation.query.get(ob_b.id).weight_remaining_main_karat == 100.0
        assert SupplierGoldAdvance.query.get(advance_a.id).weight_remaining_main_karat == 50.0

    def test_calling_twice_does_not_double_allocate(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=40.0)

        svc = GoldAllocationService()
        svc.auto_allocate_for_advance(advance)
        db.session.commit()
        second_plan = svc.auto_allocate_for_advance(advance)
        db.session.commit()

        assert second_plan.lines == [], 'a spent advance must find nothing left to allocate'
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 60.0
        rows = GoldAllocation.query.filter_by(advance_id=advance.id).all()
        assert len(rows) == 1, 'the second call must not create a second allocation row'


class TestAutoAllocateForObligation:

    def test_fifo_covers_older_advance_first_then_spills_to_newer(self):
        supplier = _supplier()
        older_advance = _advance(
            supplier.id, karat=21.0, weight=30.0,
            created_at=datetime.now() - timedelta(days=10),
        )
        newer_advance = _advance(
            supplier.id, karat=21.0, weight=100.0,
            created_at=datetime.now(),
        )
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=50.0)

        plan = GoldAllocationService().auto_allocate_for_obligation(ob)
        db.session.commit()

        assert plan.total_allocated == 50.0
        assert plan.unallocated_remainder == 0.0
        assert SupplierGoldAdvance.query.get(older_advance.id).weight_remaining_main_karat == 0.0
        assert SupplierGoldAdvance.query.get(newer_advance.id).weight_remaining_main_karat == 80.0
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 0.0


class TestManualAllocate:

    def test_writes_row_and_decrements_both_balances(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=60.0)

        allocation = GoldAllocationService().manual_allocate(
            advance_id=advance.id, obligation_id=ob.id, weight_main_karat=25.0,
        )
        db.session.commit()

        assert allocation.weight_applied_main_karat == 25.0
        assert SupplierGoldAdvance.query.get(advance.id).weight_remaining_main_karat == 35.0
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 75.0

    def test_allows_cross_karat_unlike_auto_allocation(self):
        """The override path is deliberately NOT restricted to same-karat —
        a human decides the karat_diff fee elsewhere; this only proves the
        weight-matching side of an already-decided cross-karat settlement
        is representable."""
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob_18k = _obligation(inv.id, karat=18.0, weight=100.0)
        advance_21k = _advance(supplier.id, karat=21.0, weight=50.0)

        allocation = GoldAllocationService().manual_allocate(
            advance_id=advance_21k.id, obligation_id=ob_18k.id, weight_main_karat=20.0,
        )
        db.session.commit()

        assert allocation.weight_applied_main_karat == 20.0
        assert SupplierGoldAdvance.query.get(advance_21k.id).weight_remaining_main_karat == 30.0
        assert InvoiceGoldObligation.query.get(ob_18k.id).weight_remaining_main_karat == 80.0

    def test_rejects_cross_supplier_override(self):
        """Unlike auto-FIFO (which never crosses suppliers by construction —
        its own candidate query filters on Invoice.supplier_id ==
        advance.supplier_id), manual_allocate takes raw ids directly, so this
        must be checked explicitly."""
        supplier_a = _supplier()
        supplier_b = _supplier()
        inv_b = _invoice(supplier_b.id)
        ob_b = _obligation(inv_b.id, karat=21.0, weight=100.0)
        advance_a = _advance(supplier_a.id, karat=21.0, weight=50.0)

        with pytest.raises(ValueError, match='supplier_mismatch'):
            GoldAllocationService().manual_allocate(
                advance_id=advance_a.id, obligation_id=ob_b.id, weight_main_karat=20.0,
            )

    def test_rejects_exceeding_advance_remaining(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=10.0)

        with pytest.raises(ValueError, match='exceeds_advance_remaining'):
            GoldAllocationService().manual_allocate(
                advance_id=advance.id, obligation_id=ob.id, weight_main_karat=20.0,
            )

    def test_rejects_exceeding_invoice_obligation_remaining(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=10.0)
        advance = _advance(supplier.id, karat=21.0, weight=100.0)

        with pytest.raises(ValueError, match='exceeds_invoice_obligation_remaining'):
            GoldAllocationService().manual_allocate(
                advance_id=advance.id, obligation_id=ob.id, weight_main_karat=20.0,
            )


class TestUnallocate:

    def test_by_advance_id_restores_both_balances_and_deletes_rows(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=40.0)
        GoldAllocationService().auto_allocate_for_advance(advance)
        db.session.commit()
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 60.0

        deleted = GoldAllocationService().unallocate(advance_id=advance.id)
        db.session.commit()

        assert deleted == 1
        assert GoldAllocation.query.filter_by(advance_id=advance.id).count() == 0
        assert SupplierGoldAdvance.query.get(advance.id).weight_remaining_main_karat == 40.0
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 100.0

    def test_requires_at_least_one_filter(self):
        with pytest.raises(ValueError, match='unallocate_requires_at_least_one_filter'):
            GoldAllocationService().unallocate()


class TestCreateGoldObligationsForInvoice:
    """The InvoiceKaratLine/InvoiceItem -> InvoiceGoldObligation normalizer —
    the load-bearing logic this whole correction exists for."""

    def test_from_karat_lines(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=21.0, weight_grams=100.0))
        db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=18.0, weight_grams=50.0))
        db.session.commit()

        obligations = create_gold_obligations_for_invoice(inv)
        db.session.commit()

        by_karat = {ob.karat: ob.weight for ob in obligations}
        assert by_karat == {21.0: 100.0, 18.0: 50.0}
        assert all(ob.weight_remaining_main_karat > 0 for ob in obligations)

    def test_from_items_only_with_quantity(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        db.session.add(InvoiceItem(
            invoice_id=inv.id, quantity=2, price=0.0, karat=21.0, weight=10.0,
        ))
        db.session.commit()

        obligations = create_gold_obligations_for_invoice(inv)
        db.session.commit()

        assert len(obligations) == 1
        assert obligations[0].karat == 21.0
        assert obligations[0].weight == 20.0, 'weight * quantity, matching the real GL-posting convention'

    def test_from_items_two_karats_produces_two_obligations(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        db.session.add(InvoiceItem(invoice_id=inv.id, quantity=1, price=0.0, karat=21.0, weight=50.0))
        db.session.add(InvoiceItem(invoice_id=inv.id, quantity=1, price=0.0, karat=18.0, weight=30.0))
        db.session.commit()

        obligations = create_gold_obligations_for_invoice(inv)
        db.session.commit()

        by_karat = {ob.karat: ob.weight for ob in obligations}
        assert by_karat == {21.0: 50.0, 18.0: 30.0}

    def test_item_falls_back_to_linked_item_karat_and_weight_when_blank(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        catalog_item = Item(item_code=f'ITM-{_uid()}', name='قطعة اختبار', karat=21.0, weight=15.0, price=0.0)
        db.session.add(catalog_item)
        db.session.flush()
        db.session.add(InvoiceItem(
            invoice_id=inv.id, item_id=catalog_item.id, quantity=1, price=0.0,
            karat=None, weight=None,
        ))
        db.session.commit()

        obligations = create_gold_obligations_for_invoice(inv)
        db.session.commit()

        assert len(obligations) == 1
        assert obligations[0].karat == 21.0
        assert obligations[0].weight == 15.0

    def test_both_sources_present_uses_karat_lines_only_no_double_count(self):
        """Phase 15A-Discovery.2's key real-data finding: the 4 real invoices
        carrying both sources have IDENTICAL per-karat totals in each — they
        must never be summed together."""
        supplier = _supplier()
        inv = _invoice(supplier.id)
        db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=21.0, weight_grams=100.0))
        db.session.add(InvoiceItem(invoice_id=inv.id, quantity=1, price=0.0, karat=21.0, weight=100.0))
        db.session.commit()

        obligations = create_gold_obligations_for_invoice(inv)
        db.session.commit()

        assert len(obligations) == 1
        assert obligations[0].weight == 100.0, 'must use karat_lines only, not sum both sources to 200'

    def test_idempotent_second_call_creates_nothing(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=21.0, weight_grams=100.0))
        db.session.commit()

        create_gold_obligations_for_invoice(inv)
        db.session.commit()
        second = create_gold_obligations_for_invoice(inv)
        db.session.commit()

        assert second == []
        assert InvoiceGoldObligation.query.filter_by(invoice_id=inv.id).count() == 1

    def test_auto_allocates_immediately_against_an_open_advance(self):
        supplier = _supplier()
        advance = _advance(supplier.id, karat=21.0, weight=40.0)
        inv = _invoice(supplier.id)
        db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=21.0, weight_grams=100.0))
        db.session.commit()

        obligations = create_gold_obligations_for_invoice(inv)
        db.session.commit()

        assert len(obligations) == 1
        assert obligations[0].weight_remaining_main_karat == 60.0
        assert SupplierGoldAdvance.query.get(advance.id).weight_remaining_main_karat == 0.0


def _gold_advance_voucher(supplier_id, *, karat=21.0, weight=40.0, reference_type='gold_advance'):
    """A voucher shaped like sync_gold_advance_after_voucher_approval expects:
    real VoucherAccountLine rows, amount_type='gold', line_type='debit' (the
    party/supplier side — Phase 12E's empirically verified direction)."""
    v = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=supplier_id, reference_type=reference_type,
        status='approved', created_by='test',
    )
    db.session.add(v)
    db.session.flush()
    db.session.add(VoucherAccountLine(
        voucher_id=v.id, account_id=1, line_type='debit', amount_type='gold',
        amount=weight, karat=karat,
    ))
    db.session.add(VoucherAccountLine(
        voucher_id=v.id, account_id=1, line_type='credit', amount_type='gold',
        amount=weight, karat=karat,
    ))
    db.session.commit()
    return v


class TestSyncGoldAdvanceAfterVoucherApproval:

    def test_creates_advance_from_gold_debit_lines(self):
        supplier = _supplier()
        voucher = _gold_advance_voucher(supplier.id, karat=21.0, weight=40.0)

        sync_gold_advance_after_voucher_approval(voucher)
        db.session.commit()

        advance = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).first()
        assert advance is not None
        assert advance.karat == 21.0
        assert advance.weight == 40.0

    def test_calling_twice_for_the_same_voucher_creates_nothing_new(self):
        supplier = _supplier()
        voucher = _gold_advance_voucher(supplier.id, karat=21.0, weight=40.0)

        sync_gold_advance_after_voucher_approval(voucher)
        db.session.commit()
        first_count = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).count()

        sync_gold_advance_after_voucher_approval(voucher)
        db.session.commit()
        second_count = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).count()

        assert first_count == 1
        assert second_count == 1, 'a retried call must not create a second Advance row for the same karat'

    def test_ignores_a_non_gold_advance_voucher(self):
        """Guards the no-backfill rule at its source: any voucher whose
        reference_type is not literally 'gold_advance' — including every one
        of the 289 real historical gold vouchers from Phase 12E, all
        predating this column's very existence — must never get swept into
        SupplierGoldAdvance, no matter how much real gold weight it moved."""
        supplier = _supplier()
        historical_voucher = _gold_advance_voucher(
            supplier.id, karat=21.0, weight=500.0, reference_type=None,
        )

        sync_gold_advance_after_voucher_approval(historical_voucher)
        db.session.commit()

        assert SupplierGoldAdvance.query.filter_by(source_voucher_id=historical_voucher.id).count() == 0


class TestReverseGoldAllocationsForInvoice:

    def test_frees_a_real_allocation_and_restores_both_balances(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)
        ob = _obligation(inv.id, karat=21.0, weight=100.0)
        advance = _advance(supplier.id, karat=21.0, weight=40.0)
        GoldAllocationService().auto_allocate_for_advance(advance)
        db.session.commit()
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 60.0

        freed = reverse_gold_allocations_for_invoice(inv.id)
        db.session.commit()

        assert freed == 1
        assert InvoiceGoldObligation.query.get(ob.id).weight_remaining_main_karat == 100.0
        assert SupplierGoldAdvance.query.get(advance.id).weight_remaining_main_karat == 40.0
        assert GoldAllocation.query.filter_by(obligation_id=ob.id).count() == 0

    def test_is_a_noop_for_an_invoice_with_no_obligations(self):
        supplier = _supplier()
        inv = _invoice(supplier.id)

        freed = reverse_gold_allocations_for_invoice(inv.id)

        assert freed == 0
