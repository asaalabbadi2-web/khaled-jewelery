"""Phase B-correction — cash and gold must prove settlement with equal force.

Phase B made `paid` mean "cash settled AND gold settled". But approving a
standalone voucher tagged to an invoice recorded the GOLD attribution and left
the CASH invisible, because InvoicePayment rows are only ever created by the
invoice's own payment routes. The contract was therefore lopsided:

    gold -> attributed
    cash -> invisible

That is not a new defect — Phase 11 measured 176 real supplier-payment vouchers
worth ~1,811,015 SAR with no invoice link at all, more in value than the 74
linked ones. It became a contract problem only once status started depending on
attribution.

THE RED WITNESS is test_standalone_voucher_proves_gold_and_cash_equally: before
the fix it fails on the cash half while the gold half already passes.

Run:
    python -m pytest tests/test_voucher_cash_payment_symmetry.py -v
"""

import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    Account,
    GoldAttributionBoundary,
    Invoice,
    InvoiceGoldObligation,
    InvoicePayment,
    PaymentMethod,
    Supplier,
    Voucher,
    VoucherAccountLine,
    db,
)
from party_account_service import ensure_supplier_accounts
from services.invoice_payment_state_service import InvoicePaymentStateService


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

    # Boundary 0 = nothing is historical, so the vouchers these tests create are
    # on the recorded side of the line. The protection it provides is exercised
    # explicitly by TestHistoricalVouchersAreLeftAlone below.
    if GoldAttributionBoundary.query.first() is None:
        db.session.add(GoldAttributionBoundary(max_historical_voucher_id=0))
        db.session.flush()
    # Every real purchase-invoice payment in production uses the cash method
    # (all 24 of them), so that convention is what the voucher path resolves.
    if PaymentMethod.query.filter_by(payment_type='cash').first() is None:
        db.session.add(PaymentMethod(
            name='نقداً', payment_type='cash',
            auto_settlement_enabled=False, settlement_schedule_type='none',
            commission_fixed_amount=0.0, settlement_mode='bulk',
        ))
        db.session.flush()

    yield

    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


def _uid():
    return uuid.uuid4().hex[:8]


def _account():
    a = Account(account_number=f'9{_uid()[:5]}', name=f'ح {_uid()}', type='Liability')
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


def _invoice(supplier_id, *, cash_obligation=1000.0, tracked=True):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
        supplier_id=supplier_id, date=datetime.now(),
        total=99999.0, wage_subtotal=cash_obligation,
        status='unpaid', amount_paid=0.0, is_posted=True,
        gold_settlement_tracked=tracked,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _standalone_voucher(invoice, *, cash=0.0, gold_karat=21.0, gold_weight=0.0,
                        status='approved'):
    """The shape the employee's "this payment is for invoice X" choice creates:
    a voucher tagged to the invoice, carrying cash and/or gold debit lines."""
    v = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=invoice.supplier_id,
        reference_type='invoice', reference_id=invoice.id,
        status=status, created_by='tester',
    )
    db.session.add(v)
    db.session.flush()
    if cash:
        db.session.add(VoucherAccountLine(
            voucher_id=v.id, account_id=_account().id, line_type='debit',
            amount_type='cash', amount=cash,
        ))
    if gold_weight:
        db.session.add(VoucherAccountLine(
            voucher_id=v.id, account_id=_account().id, line_type='debit',
            amount_type='gold', amount=gold_weight, karat=gold_karat,
        ))
    db.session.flush()
    return v


def _approve(voucher):
    """Everything the approval path does for gold and cash attribution."""
    from services.gold_allocation_service import (
        sync_gold_attribution_after_voucher_approval,
    )
    sync_gold_attribution_after_voucher_approval(voucher)
    try:
        from services.invoice_payment_state_service import (
            sync_invoice_cash_payment_after_voucher_approval,
        )
    except ImportError:
        return  # not written yet — this is what the red witness proves
    sync_invoice_cash_payment_after_voucher_approval(voucher)


# ======================================================================
# THE RED WITNESS
# ======================================================================

class TestSymmetry:

    def test_standalone_voucher_proves_gold_and_cash_equally(self):
        """One voucher, tagged to one invoice, paying both its obligations in
        full. Either both sides register or the contract 'paid = cash AND gold'
        is only half enforceable."""
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=1000.0)
        db.session.add(InvoiceGoldObligation(
            invoice_id=invoice.id, karat=21.0, weight=100.0,
        ))
        db.session.flush()

        voucher = _standalone_voucher(
            invoice, cash=1000.0, gold_karat=21.0, gold_weight=100.0,
        )
        _approve(voucher)

        state = InvoicePaymentStateService().recompute(invoice)

        assert state.gold_attributed_main_karat == 100.0, 'the gold half already worked'
        assert state.amount_paid == 1000.0, \
            'the cash half must register too — otherwise a standalone voucher can ' \
            'prove gold settlement and never cash'
        assert state.status == 'paid'


# ======================================================================
# The four cases the single writer has to get right
# ======================================================================

class TestSingleWriter:

    def test_a_standalone_voucher_creates_exactly_one_payment(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        voucher = _standalone_voucher(invoice, cash=500.0)

        _approve(voucher)

        rows = InvoicePayment.query.filter_by(invoice_id=invoice.id).all()
        assert len(rows) == 1
        assert rows[0].source_voucher_id == voucher.id, \
            'source_voucher_id is the idempotency key and must be set'
        assert rows[0].amount == 500.0

    def test_re_approving_creates_no_second_payment(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        voucher = _standalone_voucher(invoice, cash=500.0)

        _approve(voucher)
        _approve(voucher)

        assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 1

    def test_a_payment_the_invoice_route_already_recorded_is_not_duplicated(self):
        """The invoice's own payment routes create the InvoicePayment AND approve
        their voucher inline in the same request. The approval hook must find
        that row and add nothing."""
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        voucher = _standalone_voucher(invoice, cash=500.0)

        method = PaymentMethod.query.filter_by(payment_type='cash').first()
        db.session.add(InvoicePayment(
            invoice_id=invoice.id, payment_method_id=method.id,
            amount=500.0, net_amount=500.0, source_voucher_id=voucher.id,
        ))
        db.session.flush()

        _approve(voucher)

        assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 1

    def test_an_unapproved_voucher_records_nothing(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        voucher = _standalone_voucher(invoice, cash=500.0, status='pending')

        _approve(voucher)

        assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 0

    def test_a_voucher_not_tagged_to_an_invoice_records_nothing(self):
        """A general supplier settlement stays exactly that on the cash side
        too — it reduces the supplier's ledger balance and settles no invoice."""
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        voucher = _standalone_voucher(invoice, cash=500.0)
        voucher.reference_type = 'gold_supplier'
        voucher.reference_id = None
        db.session.flush()

        _approve(voucher)

        assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 0

    def test_a_gold_only_voucher_records_no_cash_payment(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        db.session.add(InvoiceGoldObligation(
            invoice_id=invoice.id, karat=21.0, weight=50.0,
        ))
        db.session.flush()
        voucher = _standalone_voucher(invoice, gold_karat=21.0, gold_weight=50.0)

        _approve(voucher)

        assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 0
        assert InvoicePaymentStateService().recompute(invoice).amount_paid == 0.0

    def test_amount_stays_cash_only_and_never_carries_weight(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        db.session.add(InvoiceGoldObligation(
            invoice_id=invoice.id, karat=21.0, weight=80.0,
        ))
        db.session.flush()
        voucher = _standalone_voucher(
            invoice, cash=500.0, gold_karat=21.0, gold_weight=80.0,
        )

        _approve(voucher)

        row = InvoicePayment.query.filter_by(invoice_id=invoice.id).one()
        assert row.amount == 500.0, 'the 80 g must not be folded into a currency field'


# ======================================================================
# The forward-only boundary, and why it is not optional
# ======================================================================

class TestHistoricalVouchersAreLeftAlone:

    def test_a_voucher_at_or_below_the_boundary_records_nothing(self):
        """Real data check that forced this: of 2,433 approved invoice-tagged
        vouchers, ZERO carry an InvoicePayment with source_voucher_id set — the
        column is NULL on every pre-existing row. So the idempotency key cannot
        see their payments, and re-approving any of the 2,392 cash-carrying ones
        would create a duplicate and inflate amount_paid. Below the line we
        record nothing."""
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        voucher = _standalone_voucher(invoice, cash=500.0)

        boundary = GoldAttributionBoundary.query.first()
        boundary.max_historical_voucher_id = voucher.id
        db.session.flush()

        _approve(voucher)

        assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 0, \
            'a historical voucher must never gain a payment retroactively'

    def test_a_voucher_above_the_boundary_records_normally(self):
        supplier = _supplier()
        invoice = _invoice(supplier.id, cash_obligation=500.0)
        voucher = _standalone_voucher(invoice, cash=500.0)

        boundary = GoldAttributionBoundary.query.first()
        boundary.max_historical_voucher_id = voucher.id - 1
        db.session.flush()

        _approve(voucher)

        assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 1
