"""A recompute never lowers a historical invoice's payment state on missing
evidence (stage-4 item 24, PAYSTATE-001; the owner, 12 Oct 2026: «ابنها»).

Recording payment evidence -- the payment row, the gold attribution -- began
on 24 Sep 2026 (the gold attribution boundary). Before it, an invoice's state
was written once, its evidence never recorded: on the 12 Oct backup 72 posted
invoices, all dated 9 Feb - 14 Sep, would change on a recompute -- 34 supplier
purchases from «paid» to «unpaid» (1,267,723). A recompute runs on an old
invoice when a return posts against it, a voucher naming it is approved or
cancelled, it is unposted and re-posted, or gold is allocated to it.

The rule: for an invoice up to the historical line (data, written once by its
migration, as the voucher boundary is), a recompute keeps the stored status
and amount where its own answer is lower -- unless the lowering is recorded
evidence: a payment row whose voucher was cancelled. New evidence raises it.
After the line, the records alone decide, as before.

Run:
    python -m pytest tests/test_historical_payment_state_is_kept.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import GoldAttributionBoundary, Invoice, InvoicePayment, PaymentMethod, Voucher, db
from services.invoice_payment_state_service import InvoicePaymentStateService


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


def _purchase(*, total, stored_paid, status):
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء', date=datetime(2026, 3, 12),
                  total=total, status=status, amount_paid=stored_paid, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    return inv


def _line(at_invoice_id):
    row = GoldAttributionBoundary.query.order_by(GoldAttributionBoundary.id).first()
    if row is None:
        row = GoldAttributionBoundary(max_historical_voucher_id=0)
        db.session.add(row)
    row.max_historical_invoice_id = at_invoice_id
    db.session.flush()


@pytest.fixture
def method():
    pm = PaymentMethod(name=f'نقداً {_uid()}', payment_type='cash')
    db.session.add(pm)
    db.session.flush()
    return pm


def test_a_historical_paid_purchase_with_no_rows_stays_paid():
    inv = _purchase(total=42575.0, stored_paid=42575.0, status='paid')
    _line(inv.id)
    state = InvoicePaymentStateService().recompute(inv)
    assert (inv.status, inv.amount_paid) == ('paid', 42575.0), 'not lowered on missing evidence'
    assert state.status == 'paid' and not state.changed


def test_new_evidence_raises_a_historical_invoice(method):
    inv = _purchase(total=170349.0, stored_paid=150000.0, status='partially_paid')
    _line(inv.id)
    db.session.add_all([InvoicePayment(invoice_id=inv.id, payment_method_id=method.id, amount=a, net_amount=a)
                        for a in (150000.0, 20349.0)])
    db.session.flush()
    InvoicePaymentStateService().recompute(inv)
    assert (inv.status, inv.amount_paid) == ('paid', 170349.0)


def test_after_the_line_the_records_alone_decide():
    inv = _purchase(total=1000.0, stored_paid=1000.0, status='paid')
    _line(inv.id - 1)
    InvoicePaymentStateService().recompute(inv)
    assert (inv.status, inv.amount_paid) == ('unpaid', 0.0)


def test_a_cancelled_voucher_lowers_a_historical_invoice(method):
    inv = _purchase(total=1000.0, stored_paid=1000.0, status='paid')
    _line(inv.id)
    v = Voucher(voucher_number=f'PV-T-{_uid()}', voucher_type='payment', date=datetime(2026, 3, 12),
                status='cancelled', amount_cash=1000.0, created_by='t', reference_type='invoice', reference_id=inv.id)
    db.session.add(v)
    db.session.flush()
    db.session.add(InvoicePayment(invoice_id=inv.id, payment_method_id=method.id, amount=1000.0, net_amount=1000.0,
                                  source_voucher_id=v.id))
    db.session.flush()
    InvoicePaymentStateService().recompute(inv)
    assert inv.status == 'unpaid', 'the cancellation is recorded evidence'


def test_no_line_no_protection():
    """Fails closed toward the records, as the voucher boundary does."""
    inv = _purchase(total=500.0, stored_paid=500.0, status='paid')
    _line(None)
    InvoicePaymentStateService().recompute(inv)
    assert inv.status == 'unpaid'
