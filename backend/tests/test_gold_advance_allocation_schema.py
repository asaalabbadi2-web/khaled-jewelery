"""Phase 15A-Correction — schema/model tests for Supplier Gold Advance &
Allocation.

Scope, deliberately narrow (see the Phase 15 sub-phase plan in project
memory): SupplierGoldAdvance, InvoiceGoldObligation, and GoldAllocation as
pure models/schema — no service-level FIFO logic, no route, no trigger.
Those are tested in test_gold_allocation_service.py (15B) and belong to
15C's own wiring.

WHY InvoiceGoldObligation, not a balance column on InvoiceKaratLine (the
original, since-corrected 15A design): Phase 15A-Discovery.2 proved real
'شراء' purchase invoices record their own gold weight through EITHER
InvoiceKaratLine (33/180 real invoices) OR InvoiceItem (147/180) — a
per-InvoiceKaratLine-row balance is blind to 81.7% of real invoices.
InvoiceGoldObligation is the single, source-agnostic ledger normalized from
whichever source an invoice actually used, at (invoice, karat) granularity —
matching the real GL itself, which posts one memo-account credit per
invoice per karat, never one per line/item.

Karat rule under test throughout: obligations and settlements keep their own
real karat; only a running balance (weight_remaining_main_karat, on both
InvoiceGoldObligation and SupplierGoldAdvance) is main-karat-equivalent.
"""

import uuid
from datetime import datetime

import pytest
from sqlalchemy.exc import IntegrityError

from app import app as flask_app
from models import (
    GoldAllocation,
    Invoice,
    InvoiceGoldObligation,
    Supplier,
    SupplierGoldAdvance,
    Voucher,
    db,
)


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


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier():
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد اختبار {_uid()}')
    db.session.add(s)
    db.session.flush()
    return s


def _voucher(supplier_id):
    v = Voucher(
        voucher_number=f'V-{_uid()}',
        voucher_type='payment',
        date=datetime.now(),
        party_type='supplier',
        supplier_id=supplier_id,
        reference_type='gold_advance',
        status='approved',
        created_by='test',
    )
    db.session.add(v)
    db.session.flush()
    return v


def _purchase_invoice(supplier_id):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type='شراء',
        supplier_id=supplier_id,
        date=datetime.now(),
        total=1000.0,
        status='unpaid',
        amount_paid=0.0,
        is_posted=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _obligation(invoice_id, *, karat=21.0, weight=100.0, remaining=None):
    ob = InvoiceGoldObligation(
        invoice_id=invoice_id,
        karat=karat,
        weight=weight,
        weight_remaining_main_karat=remaining if remaining is not None else weight,
    )
    db.session.add(ob)
    db.session.flush()
    return ob


class TestSupplierGoldAdvance:

    def test_create_with_real_karat_and_main_karat_balance(self):
        supplier = _supplier()
        voucher = _voucher(supplier.id)

        advance = SupplierGoldAdvance(
            supplier_id=supplier.id,
            source_voucher_id=voucher.id,
            karat=18.0,
            weight=100.0,
            weight_remaining_main_karat=85.71,  # 100g@18k in 21k-equivalent
        )
        db.session.add(advance)
        db.session.commit()

        fetched = SupplierGoldAdvance.query.get(advance.id)
        assert fetched.karat == 18.0, 'the real, actual karat paid must survive unconverted'
        assert fetched.weight == 100.0
        assert fetched.weight_remaining_main_karat == 85.71
        assert fetched.supplier.id == supplier.id
        assert fetched.source_voucher.id == voucher.id

    def test_same_voucher_two_karats_both_allowed(self):
        """A single voucher paying two karats at once (real, observed pattern —
        Phase 12E found 2.7% of real gold-bearing GL lines carry two karats)
        must produce two independent SupplierGoldAdvance rows, not collide."""
        supplier = _supplier()
        voucher = _voucher(supplier.id)

        db.session.add(SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id,
            karat=18.0, weight=100.0, weight_remaining_main_karat=85.71,
        ))
        db.session.add(SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id,
            karat=24.0, weight=50.0, weight_remaining_main_karat=57.14,
        ))
        db.session.commit()

        rows = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).all()
        assert len(rows) == 2

    def test_same_voucher_same_karat_twice_is_rejected(self):
        """The one uniqueness rule that exists: a given voucher must never
        produce two separate Advance rows for the SAME karat — that would be
        a double-count of one real payment, not two real payments."""
        supplier = _supplier()
        voucher = _voucher(supplier.id)

        db.session.add(SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id,
            karat=21.0, weight=100.0, weight_remaining_main_karat=100.0,
        ))
        db.session.commit()

        db.session.add(SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id,
            karat=21.0, weight=40.0, weight_remaining_main_karat=40.0,
        ))
        with pytest.raises(IntegrityError):
            db.session.commit()
        db.session.rollback()


class TestInvoiceGoldObligation:

    def test_create_with_real_karat_and_main_karat_balance(self):
        supplier = _supplier()
        inv = _purchase_invoice(supplier.id)
        obligation = _obligation(inv.id, karat=21.0, weight=1406.17, remaining=1406.17)

        fetched = InvoiceGoldObligation.query.get(obligation.id)
        assert fetched.karat == 21.0
        assert fetched.weight == 1406.17
        assert fetched.weight_remaining_main_karat == 1406.17
        assert fetched.invoice.id == inv.id

    def test_to_dict_exposes_all_fields(self):
        supplier = _supplier()
        inv = _purchase_invoice(supplier.id)
        obligation = _obligation(inv.id, karat=21.0, weight=100.0, remaining=100.0)

        d = obligation.to_dict()
        assert d['invoice_id'] == inv.id
        assert d['karat'] == 21.0
        assert d['weight'] == 100.0
        assert d['weight_remaining_main_karat'] == 100.0

    def test_same_invoice_two_karats_both_allowed(self):
        """A mixed-karat purchase invoice must produce one obligation row per
        karat, not collide."""
        supplier = _supplier()
        inv = _purchase_invoice(supplier.id)
        _obligation(inv.id, karat=18.0, weight=100.0)
        _obligation(inv.id, karat=21.0, weight=50.0)
        db.session.commit()

        rows = InvoiceGoldObligation.query.filter_by(invoice_id=inv.id).all()
        assert len(rows) == 2

    def test_same_invoice_same_karat_twice_is_rejected(self):
        """One row per (invoice, karat) — a second row for the same karat on
        the same invoice would double the obligation, not represent a real
        second debt."""
        supplier = _supplier()
        inv = _purchase_invoice(supplier.id)
        _obligation(inv.id, karat=21.0, weight=100.0)
        db.session.commit()

        db.session.add(InvoiceGoldObligation(
            invoice_id=inv.id, karat=21.0, weight=50.0, weight_remaining_main_karat=50.0,
        ))
        with pytest.raises(IntegrityError):
            db.session.commit()
        db.session.rollback()


class TestGoldAllocation:

    def test_create_links_advance_to_obligation(self):
        supplier = _supplier()
        voucher = _voucher(supplier.id)
        inv = _purchase_invoice(supplier.id)
        obligation = _obligation(inv.id, karat=21.0, weight=100.0, remaining=100.0)
        advance = SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id,
            karat=21.0, weight=60.0, weight_remaining_main_karat=60.0,
        )
        db.session.add(advance)
        db.session.flush()

        allocation = GoldAllocation(
            advance_id=advance.id,
            obligation_id=obligation.id,
            weight_applied_main_karat=60.0,
        )
        db.session.add(allocation)
        db.session.commit()

        fetched = GoldAllocation.query.get(allocation.id)
        assert fetched.advance.id == advance.id
        assert fetched.obligation.id == obligation.id
        assert fetched.weight_applied_main_karat == 60.0

    def test_same_advance_and_obligation_can_receive_a_second_allocation_row(self):
        """Deliberately unconstrained (mirrors SettlementLine's own
        append-only, multi-row-per-pair design) — a second partial
        allocation between the same advance/obligation must not be blocked."""
        supplier = _supplier()
        voucher = _voucher(supplier.id)
        inv = _purchase_invoice(supplier.id)
        obligation = _obligation(inv.id, karat=21.0, weight=100.0, remaining=100.0)
        advance = SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id,
            karat=21.0, weight=100.0, weight_remaining_main_karat=100.0,
        )
        db.session.add(advance)
        db.session.flush()

        db.session.add(GoldAllocation(
            advance_id=advance.id, obligation_id=obligation.id, weight_applied_main_karat=30.0,
        ))
        db.session.add(GoldAllocation(
            advance_id=advance.id, obligation_id=obligation.id, weight_applied_main_karat=20.0,
        ))
        db.session.commit()

        rows = GoldAllocation.query.filter_by(advance_id=advance.id, obligation_id=obligation.id).all()
        assert len(rows) == 2
        assert sum(r.weight_applied_main_karat for r in rows) == 50.0
