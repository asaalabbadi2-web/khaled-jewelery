"""A supplier purchase's payment voucher linked to the payment row it made
(stage-4 item 2, LINK-001).

22 supplier purchases hold a payment row of their payment voucher's own
amount, unlinked (source_voucher_id NULL) -- the cash IS counted, only the link
is missing. Attributing again would count it twice; linking changes no
amount: the voucher is not cancelled, so its payment counts as before. The
link is what a later cancellation of the voucher, the retraction guard's
message and a re-approval's idempotency read. Only a one-to-one match is
linked: one unlinked row of the voucher's amount, claimed by no other voucher.

Run:
    python -m pytest tests/test_payment_voucher_links_repair.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Invoice, InvoicePayment, PaymentMethod, Voucher, db
from services.invoice_payment_state_service import InvoicePaymentStateService
from services.repair.payment_voucher_links import link_payment_vouchers


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:8]


@pytest.fixture
def cash():
    pm = PaymentMethod(name=f'نقدي {_uid()}', payment_type='cash')
    db.session.add(pm)
    db.session.flush()
    return pm


def _purchase(total=1000.0):
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء', date=datetime(2026, 5, 1),
                  total=total, status='unpaid', amount_paid=0.0, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    return inv


def _voucher(inv, amount, status='approved'):
    v = Voucher(voucher_number=f'PV-{_uid()}', voucher_type='payment', date=datetime(2026, 5, 2),
                reference_type='invoice', reference_id=inv.id, status=status, created_by='t', amount_cash=amount)
    db.session.add(v)
    db.session.flush()
    return v


def _payment(inv, pm, amount, voucher=None):
    ip = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=amount, net_amount=amount,
                        source_voucher_id=voucher.id if voucher else None)
    db.session.add(ip)
    db.session.flush()
    return ip


def test_a_voucher_is_linked_to_its_one_payment_row_and_nothing_counts_twice(cash):
    inv = _purchase()
    v = _voucher(inv, 600.0)
    ip = _payment(inv, cash, 600.0)
    _payment(inv, cash, 400.0)
    state = InvoicePaymentStateService()
    before = state.recompute(inv)

    dry = link_payment_vouchers(by='t', dry_run=True, invoice_ids=[inv.id])
    assert [l['voucher_id'] for l in dry['linked']] == [v.id]
    assert db.session.get(InvoicePayment, ip.id).source_voucher_id is None, 'dry run writes nothing'

    link_payment_vouchers(by='t', dry_run=False, invoice_ids=[inv.id])
    assert db.session.get(InvoicePayment, ip.id).source_voucher_id == v.id
    after = state.recompute(inv)
    assert (after.amount_paid, after.status) == (before.amount_paid, before.status), 'no amount moves'

    v.status = 'cancelled'
    db.session.flush()
    assert state.recompute(inv).amount_paid == pytest.approx(400.0), 'a cancelled voucher\'s payment now drops'
    assert link_payment_vouchers(by='t', dry_run=True, invoice_ids=[inv.id])['linked'] == []


def test_two_rows_of_the_voucher_amount_are_not_guessed(cash):
    inv = _purchase()
    _voucher(inv, 500.0)
    _payment(inv, cash, 500.0)
    _payment(inv, cash, 500.0)
    plan = link_payment_vouchers(by='t', dry_run=True, invoice_ids=[inv.id])
    assert plan['linked'] == [] and plan['ambiguous'], 'said, not linked'


def test_a_row_linked_already_or_a_voucher_not_approved_is_left(cash):
    inv = _purchase()
    other = _voucher(inv, 300.0)
    _payment(inv, cash, 300.0, voucher=other)
    _voucher(inv, 300.0)
    _voucher(inv, 200.0, status='pending')
    _payment(inv, cash, 200.0)
    assert link_payment_vouchers(by='t', dry_run=True, invoice_ids=[inv.id])['linked'] == []
