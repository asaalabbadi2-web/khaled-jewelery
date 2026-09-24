"""Phase B — an invoice is paid when BOTH obligations are, not just the cash.

A purchase invoice owes cash and gold. Paying 5,000 SAR and 120 g of a 200 g
obligation leaves 80 g outstanding, and reporting that as 'paid' because the
cash cleared is the same half-truth this whole audit started from.

The load-bearing test is TestUntrackedInvoicesAreUnchanged: every invoice
predating Phase A keeps its cash-only meaning exactly. Measured before shipping
— of 149 real invoices with a gold obligation only 21 had attributable
settlement, so a retroactive rule would have marked settled invoices unpaid.

Run:
    python -m pytest tests/test_invoice_settlement_state.py -v
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
from services.gold_allocation_service import attribute_gold_to_invoice
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


def _supplier():
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


def _purchase_invoice(supplier_id, *, cash_obligation=1000.0, tracked=False):
    """A purchase invoice whose cash ceiling is wage + taxes (Phase 13's
    cash_obligation), expressed here through wage_subtotal."""
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


def _cash_method():
    pm = PaymentMethod.query.filter_by(name='نقد اختبار').first()
    if pm is None:
        pm = PaymentMethod(
            name='نقد اختبار', payment_type='cash',
            auto_settlement_enabled=False, settlement_schedule_type='none',
            commission_fixed_amount=0.0, settlement_mode='immediate',
        )
        db.session.add(pm)
        db.session.flush()
    return pm


def _pay_cash(invoice, amount):
    db.session.add(InvoicePayment(
        invoice_id=invoice.id, payment_method_id=_cash_method().id,
        amount=amount, net_amount=amount,
    ))
    db.session.flush()


def _obligation(invoice_id, *, karat=21.0, weight=200.0):
    ob = InvoiceGoldObligation(invoice_id=invoice_id, karat=karat, weight=weight)
    db.session.add(ob)
    db.session.flush()
    return ob


def _pay_gold(invoice, *, karat=21.0, weight=100.0):
    account = Account(account_number=f'9{_uid()[:5]}', name=f'ح {_uid()}', type='Liability')
    db.session.add(account)
    db.session.flush()
    voucher = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=invoice.supplier_id,
        reference_type='invoice', reference_id=invoice.id,
        status='approved', created_by='tester',
    )
    db.session.add(voucher)
    db.session.flush()
    db.session.add(VoucherAccountLine(
        voucher_id=voucher.id, account_id=account.id, line_type='debit',
        amount_type='gold', amount=weight, karat=karat,
    ))
    db.session.flush()
    attribute_gold_to_invoice(
        voucher=voucher, invoice_id=invoice.id, karat=karat, weight=weight,
    )
    return voucher


def _status(invoice):
    return InvoicePaymentStateService().recompute(invoice).status


# ======================================================================
# THE GATE: history keeps its meaning
# ======================================================================

class TestUntrackedInvoicesAreUnchanged:

    def test_cash_alone_still_decides_an_untracked_invoice(self):
        """gold_settlement_tracked=False means the gold side is UNTRACKED, not
        unsettled: an open gold obligation must not drag the status down."""
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=1000.0, tracked=False)
        _obligation(invoice.id, karat=21.0, weight=200.0)

        _pay_cash(invoice, 1000.0)
        assert _status(invoice) == 'paid', \
            'a pre-Phase-A invoice with its cash settled stays paid'

    def test_the_gold_dimension_is_reported_as_absent_not_zero(self):
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, tracked=False)
        _obligation(invoice.id, karat=21.0, weight=200.0)

        state = InvoicePaymentStateService().recompute(invoice)
        assert state.gold_required_main_karat is None
        assert state.gold_attributed_main_karat is None


# ======================================================================
# The four quadrants, for a tracked invoice
# ======================================================================

class TestTrackedInvoiceNeedsBothSides:

    def test_neither_side_settled_is_unpaid(self):
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=5000.0, tracked=True)
        _obligation(invoice.id, karat=21.0, weight=200.0)
        assert _status(invoice) == 'unpaid'

    def test_cash_settled_gold_not_is_partial(self):
        """The case the old model got wrong: cash cleared, 80 g still owed."""
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=5000.0, tracked=True)
        _obligation(invoice.id, karat=21.0, weight=200.0)

        _pay_cash(invoice, 5000.0)
        _pay_gold(invoice, karat=21.0, weight=120.0)

        state = InvoicePaymentStateService().recompute(invoice)
        assert state.status == 'partially_paid'
        assert state.gold_required_main_karat == 200.0
        assert state.gold_attributed_main_karat == 120.0

    def test_gold_settled_cash_not_is_partial(self):
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=5000.0, tracked=True)
        _obligation(invoice.id, karat=21.0, weight=200.0)

        _pay_gold(invoice, karat=21.0, weight=200.0)

        assert _status(invoice) == 'partially_paid'

    def test_both_settled_is_paid(self):
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=5000.0, tracked=True)
        _obligation(invoice.id, karat=21.0, weight=200.0)

        _pay_cash(invoice, 5000.0)
        _pay_gold(invoice, karat=21.0, weight=200.0)

        assert _status(invoice) == 'paid'

    def test_a_tracked_invoice_with_no_gold_obligation_is_decided_by_cash(self):
        """Vacuously satisfied: no gold owed must not hold an invoice at
        partial forever."""
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=5000.0, tracked=True)

        _pay_cash(invoice, 5000.0)
        assert _status(invoice) == 'paid'

    def test_gold_paid_in_a_different_karat_still_settles(self):
        """Phase 16A: 8 of 34 real settlements paid a karat the invoice never
        contained. The equivalent is what balances."""
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=0.0, tracked=True)
        _obligation(invoice.id, karat=21.0, weight=90.0)

        # 105 g of 18k is exactly 90 g of 21k — the equivalent is what balances,
        # and the ceiling check rightly refuses anything above it.
        _pay_gold(invoice, karat=18.0, weight=105.0)

        state = InvoicePaymentStateService().recompute(invoice)
        assert state.gold_attributed_main_karat >= state.gold_required_main_karat
        assert state.status == 'paid'


# ======================================================================
# The trigger: status follows a gold event without being asked
# ======================================================================

class TestGoldEventsResyncStatus:

    def test_attributing_gold_updates_the_stored_status(self):
        """status is a stored column now depending on gold, so a gold event must
        refresh it — otherwise it drifts, which is the failure this codebase has
        produced three times already."""
        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=1000.0, tracked=True)
        _obligation(invoice.id, karat=21.0, weight=100.0)
        _pay_cash(invoice, 1000.0)
        InvoicePaymentStateService().recompute(invoice)
        assert invoice.status == 'partially_paid'

        _pay_gold(invoice, karat=21.0, weight=100.0)

        assert invoice.status == 'paid', \
            'attribute_gold_to_invoice must resync the status by itself'

    def test_removing_attribution_updates_the_stored_status(self):
        from services.gold_allocation_service import remove_attributions_for_voucher

        supplier = _supplier()
        invoice = _purchase_invoice(supplier.id, cash_obligation=1000.0, tracked=True)
        _obligation(invoice.id, karat=21.0, weight=100.0)
        _pay_cash(invoice, 1000.0)
        voucher = _pay_gold(invoice, karat=21.0, weight=100.0)
        assert invoice.status == 'paid'

        remove_attributions_for_voucher(voucher.id)

        assert invoice.status == 'partially_paid', \
            'cancelling the payment must take the invoice back off paid'


# ======================================================================
# Ratchets
# ======================================================================

class TestTrackedFlagIsWriteOnce:

    def test_only_the_invoice_creation_path_assigns_it(self):
        """Flipping an existing invoice False -> True would make its meaning
        depend on when someone happened to attach a payment to it — and would
        silently re-open the 121 invoices that have no attributable settlement.
        Exactly one assignment is allowed, in add_invoice's post-commit tail."""
        import re
        from pathlib import Path

        backend = Path(__file__).resolve().parent.parent
        pattern = re.compile(r'gold_settlement_tracked\s*=\s*(?!=)')
        allowed = {
            'models.py',                                   # the column itself
            'routes/invoices.py',                          # the one writer
            'tests/test_invoice_settlement_state.py',       # this file
            'alembic/versions/20260924_invoice_gold_settlement_tracked.py',
        }
        offenders = []
        for path in backend.rglob('*.py'):
            rel = path.relative_to(backend).as_posix()
            if rel in allowed or rel.startswith(('venv/', 'devtools/', 'tools/')):
                continue
            for line_no, line in enumerate(
                path.read_text(encoding='utf-8', errors='ignore').splitlines(), start=1
            ):
                code = line.split('#', 1)[0]
                if pattern.search(code):
                    offenders.append(f'{rel}:{line_no}: {line.strip()}')
        assert not offenders, (
            'gold_settlement_tracked is write-once at creation:\n  ' + '\n  '.join(offenders)
        )

    def test_the_single_writer_only_ever_sets_it_true(self):
        source = (
            __import__('pathlib').Path(__file__).resolve().parent.parent
            / 'routes' / 'invoices.py'
        ).read_text(encoding='utf-8')
        assignments = [
            line.strip() for line in source.splitlines()
            if 'gold_settlement_tracked =' in line.split('#', 1)[0]
        ]
        assert assignments, 'the creation path must set it'
        for line in assignments:
            assert line.endswith('= True'), f'unexpected assignment: {line}'


class TestGoldEventsAreWiredToResync:

    def test_every_gold_event_path_resyncs_invoice_status(self):
        """Invoice.status is stored and now depends on gold, so each gold event
        must refresh it. The trigger set is small on purpose — this asserts it
        stays complete."""
        from pathlib import Path

        source = (
            Path(__file__).resolve().parent.parent
            / 'services' / 'gold_allocation_service.py'
        ).read_text(encoding='utf-8')

        for func in (
            'def attribute_gold_to_invoice(',
            'def remove_attributions_for_voucher(',
            'def create_gold_obligations_for_invoice(',
            'def allocate(',
            'def unallocate(',
        ):
            start = source.index(func)
            nxt = source.find('\ndef ', start + 1)
            nxt_method = source.find('\n    def ', start + 1)
            end = min(x for x in (nxt, nxt_method, len(source)) if x > 0)
            body = source[start:end]
            assert '_resync_invoice_status(' in body, (
                f'{func.strip("def (")} does not resync the invoice status'
            )
