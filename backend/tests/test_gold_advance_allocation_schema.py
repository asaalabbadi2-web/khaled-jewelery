"""Phase 16C — the data contract of the three Gold Advance/Allocation tables.

Schema-level only: constraints, relationships, and the columns that must and
must NOT exist. Behaviour lives in test_gold_allocation_service.py.

The contract tests here are load-bearing rather than cosmetic:
test_no_stored_remaining_balance_column_exists guards the central Phase 16C
decision. Phase 16A measured a stored remaining balance drifting to 31,407g
against a real GL position of 3,446g, because the dominant real settlement
mechanism never wrote to it. Re-adding that column would silently re-open the
defect, so its absence is asserted, not assumed.

Run:
    python -m pytest tests/test_gold_advance_allocation_schema.py -v
"""

import uuid
from datetime import datetime

import pytest
from sqlalchemy import inspect as sa_inspect
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


def _invoice(supplier_id):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
        supplier_id=supplier_id, date=datetime.now(), total=1000.0,
        status='unpaid', amount_paid=0.0, is_posted=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _advance(supplier_id, *, karat=21.0, weight=100.0):
    a = SupplierGoldAdvance(
        supplier_id=supplier_id, source_voucher_id=_voucher(supplier_id).id,
        karat=karat, weight=weight,
    )
    db.session.add(a)
    db.session.flush()
    return a


def _obligation(invoice_id, *, karat=21.0, weight=100.0):
    ob = InvoiceGoldObligation(invoice_id=invoice_id, karat=karat, weight=weight)
    db.session.add(ob)
    db.session.flush()
    return ob


# ======================================================================
# The Phase 16C column contract
# ======================================================================

class TestColumnContract:

    @pytest.mark.parametrize('table', ['supplier_gold_advance', 'invoice_gold_obligation'])
    def test_no_stored_remaining_balance_column_exists(self, table):
        """Remaining weight is DERIVED, never stored — see the module
        docstring for the measured drift that forced this."""
        columns = {c['name'] for c in sa_inspect(db.engine).get_columns(table)}
        assert 'weight_remaining_main_karat' not in columns

    def test_obligation_keeps_its_real_karat_and_gross_weight(self):
        columns = {c['name'] for c in sa_inspect(db.engine).get_columns('invoice_gold_obligation')}
        assert {'invoice_id', 'karat', 'weight'} <= columns

    def test_allocation_carries_only_a_main_karat_weight(self):
        """A GoldAllocation IS a balance-reduction event, and per Phase 14 a
        balance is only ever main-karat-equivalent. The real karat of each side
        lives one hop away, never duplicated here."""
        columns = {c['name'] for c in sa_inspect(db.engine).get_columns('gold_allocation')}
        assert 'weight_applied_main_karat' in columns
        assert 'karat' not in columns

    def test_allocation_references_the_obligation_not_a_line_or_item(self):
        """Phase 15A-Correction: an obligation is (invoice, karat), never
        (line, karat) — real invoices record weight through either
        InvoiceKaratLine or InvoiceItem, so neither may be referenced."""
        columns = {c['name'] for c in sa_inspect(db.engine).get_columns('gold_allocation')}
        assert 'obligation_id' in columns
        assert 'invoice_karat_line_id' not in columns
        assert 'invoice_item_id' not in columns

    def test_advance_has_no_invoice_column(self):
        """Not being tied to an invoice is the entire point of an Advance."""
        columns = {c['name'] for c in sa_inspect(db.engine).get_columns('supplier_gold_advance')}
        assert 'invoice_id' not in columns


# ======================================================================
# Constraints
# ======================================================================

class TestSupplierGoldAdvance:

    def test_one_row_per_voucher_and_karat(self):
        supplier = _supplier()
        voucher = _voucher(supplier.id)
        db.session.add(SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id, karat=21.0, weight=50.0,
        ))
        db.session.flush()

        db.session.add(SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=voucher.id, karat=21.0, weight=10.0,
        ))
        with pytest.raises(IntegrityError):
            db.session.flush()

    def test_one_voucher_may_carry_several_karats(self):
        supplier = _supplier()
        voucher = _voucher(supplier.id)
        db.session.add_all([
            SupplierGoldAdvance(
                supplier_id=supplier.id, source_voucher_id=voucher.id, karat=18.0, weight=100.0,
            ),
            SupplierGoldAdvance(
                supplier_id=supplier.id, source_voucher_id=voucher.id, karat=24.0, weight=50.0,
            ),
        ])
        db.session.flush()

        assert SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).count() == 2

    def test_to_dict_exposes_no_remaining_key(self):
        """The route layer adds a derived remaining_main_karat; the model must
        not offer a stored-looking one."""
        supplier = _supplier()
        payload = _advance(supplier.id).to_dict()
        assert 'weight_remaining_main_karat' not in payload
        assert payload['weight'] == 100.0


class TestInvoiceGoldObligation:

    def test_one_row_per_invoice_and_karat(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=50.0)

        db.session.add(InvoiceGoldObligation(
            invoice_id=invoice.id, karat=21.0, weight=60.0,
        ))
        with pytest.raises(IntegrityError):
            db.session.flush()

    def test_one_invoice_may_carry_several_karats(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=50.0)
        _obligation(invoice.id, karat=18.0, weight=30.0)

        assert InvoiceGoldObligation.query.filter_by(invoice_id=invoice.id).count() == 2

    def test_backref_from_invoice(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        _obligation(invoice.id, karat=21.0, weight=1406.17)

        fetched = invoice.gold_obligations.one()
        assert fetched.weight == 1406.17
        assert fetched.karat == 21.0


class TestGoldAllocation:

    def test_links_an_advance_to_an_obligation(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id)
        advance = _advance(supplier.id)

        allocation = GoldAllocation(
            advance_id=advance.id, obligation_id=obligation.id,
            weight_applied_main_karat=25.0,
        )
        db.session.add(allocation)
        db.session.flush()

        assert allocation.advance.id == advance.id
        assert allocation.obligation.id == obligation.id
        assert advance.allocations.count() == 1
        assert obligation.allocations.count() == 1

    def test_allows_several_rows_for_the_same_pair(self):
        """Append-only, mirroring SettlementLine: correcting an allocation adds
        a row, it never edits one in place."""
        supplier = _supplier()
        invoice = _invoice(supplier.id)
        obligation = _obligation(invoice.id)
        advance = _advance(supplier.id)

        db.session.add_all([
            GoldAllocation(
                advance_id=advance.id, obligation_id=obligation.id,
                weight_applied_main_karat=10.0,
            ),
            GoldAllocation(
                advance_id=advance.id, obligation_id=obligation.id,
                weight_applied_main_karat=15.0,
            ),
        ])
        db.session.flush()

        assert obligation.allocations.count() == 2
