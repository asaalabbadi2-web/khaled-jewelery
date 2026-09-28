"""Clearing settlement settles payments that no longer exist.

INCIDENT, 2026-09-27: settlement AV-2026-00436 (Mada, cut-off 2026-09-26)
settled 6,530.00 when 4,380.00 was real. The difference is sales invoice 3123:
paid 2,150.00 by Mada at 08:42, rejected at 08:44, re-entered as 3124 at 08:49
and paid again. Its InvoicePayment row survived the rejection -- deliberately,
history is kept -- and the scheduler selected it, allocated it to a
SettlementLine, and charged 17.20 commission on it.

ROOT CAUSE: _get_unsettled_ip_ids_for_day and _get_unsettled_ip_ids_up_to
select InvoicePayment by payment method and time only. They apply neither rule
the rest of the codebase already has for "this payment no longer counts":
  - InvoicePaymentStateService: a payment whose creating voucher was cancelled
    is excluded (source_voucher_id IS NULL OR Voucher.status != 'cancelled').
  - gold_allocation_service.RETRACTED_INVOICE_STATUSES: a rejected or cancelled
    invoice is not a standing document.
So even a properly CANCELLED receipt voucher's payment would be settled.

WHY THE INVOICE RULE IS NEEDED AND NOT ONLY THE VOUCHER RULE: rejecting 3123
reset its receipt voucher to 'pending', not 'cancelled'. The voucher rule alone
would still have settled it.

WHY UN-SETTLING THE BAD SETTLEMENT FIRST WOULD NOT HAVE HELPED: cancelling a
clearing settlement unallocates its SettlementLines (the AV-2026-00223 fix), and
the next run selects the same four payments again -- 3123's included. The
selection has to be fixed before the settlement can be corrected.

BLAST RADIUS, measured on the post-incident production copy (2026-09-27 22:49
UTC) before writing the fix: exactly two InvoicePayment rows are dead by either
rule -- invoices 2821 and 3123, both rejected; zero belong to a cancelled
voucher. Exactly one was ever settled: 3123's 2,150.00 (commission 17.20).
The fix therefore excludes nothing that is live, which is what
TestLivePaymentsAreUnaffected exists to hold.

Run:
    python -m pytest tests/test_clearing_settlement_excludes_dead_payments.py -v
"""
import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from clearing_settlement_scheduler import ClearingSettlementScheduler
from models import (
    Account,
    Invoice,
    InvoicePayment,
    PaymentMethod,
    SafeBox,
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


# The cut-off of the real incident: payments of 2026-09-26, settled 2026-09-27.
DAY = datetime(2026, 9, 26, 0, 0, 0)
DAY_END = DAY + timedelta(days=1) - timedelta(seconds=1)


@pytest.fixture
def mada(app):
    """A clearing box and the Mada method that settles into it."""
    acc = Account(account_number=f'8{_uid()[:5]}', name=f'مقاصة {_uid()}', type='Asset')
    db.session.add(acc)
    db.session.flush()
    now = datetime.now()
    box = SafeBox(
        name=f'مدى {_uid()}', safe_type='clearing', account_id=acc.id,
        is_active=True, is_default=False, created_at=now, updated_at=now,
    )
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(name=f'مدى {_uid()}', payment_type='mada', default_safe_box_id=box.id)
    db.session.add(pm)
    db.session.flush()
    return box, pm


def _sale_paid_by(pm, amount, *, at, invoice_status='paid', voucher_status='approved',
                  with_voucher=True):
    """A sales invoice and the Mada payment taken on it, the way the POS records
    one: an InvoicePayment whose source_voucher_id is the receipt voucher."""
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع',
        date=at, total=amount, status=invoice_status, amount_paid=amount,
        is_posted=invoice_status not in ('rejected', 'cancelled'),
    )
    db.session.add(inv)
    db.session.flush()
    voucher_id = None
    if with_voucher:
        v = Voucher(
            voucher_number=f'RV-{_uid()}', voucher_type='receipt', date=at,
            reference_type='invoice', reference_id=inv.id,
            status=voucher_status, created_by='t', amount_cash=amount, created_at=at,
        )
        db.session.add(v)
        db.session.flush()
        voucher_id = v.id
    ip = InvoicePayment(
        invoice_id=inv.id, payment_method_id=pm.id, amount=amount, net_amount=amount,
        source_voucher_id=voucher_id, created_at=at,
    )
    db.session.add(ip)
    db.session.flush()
    return inv, ip


def _amounts(ip_ids):
    return round(sum(float(InvoicePayment.query.get(i).amount) for i in ip_ids), 2)


class TestIncident3123:
    """The real numbers of 2026-09-26: settlement must be 4,380, not 6,530."""

    def _replay(self, pm):
        _, dead = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=42),
                                invoice_status='rejected', voucher_status='pending')
        _, b = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=49))
        _, c = _sale_paid_by(pm, 1000.0, at=DAY.replace(hour=15, minute=35))
        _, d = _sale_paid_by(pm, 1230.0, at=DAY.replace(hour=15, minute=46))
        return dead, {b.id, c.id, d.id}

    def test_up_to_cutoff_settles_only_the_live_payments(self, app, mada):
        box, pm = mada
        dead, live = self._replay(pm)
        ids = ClearingSettlementScheduler(app)._get_unsettled_ip_ids_up_to(box.id, DAY_END)
        assert dead.id not in ids
        assert set(ids) == live
        assert _amounts(ids) == 4380.0

    def test_the_day_window_applies_the_same_rule(self, app, mada):
        box, pm = mada
        dead, live = self._replay(pm)
        ids = ClearingSettlementScheduler(app)._get_unsettled_ip_ids_for_day(box.id, DAY, DAY_END)
        assert dead.id not in ids
        assert set(ids) == live
        assert _amounts(ids) == 4380.0


class TestACancelledVoucherIsNotSettled:
    """Wider than the incident: a receipt voucher cancelled PROPERLY, on a
    standing invoice, must not be settled either -- the voucher rule that
    InvoicePaymentStateService already applies."""

    def test_cancelled_voucher_payment_is_excluded(self, app, mada):
        box, pm = mada
        _, cancelled = _sale_paid_by(pm, 500.0, at=DAY.replace(hour=10),
                                     invoice_status='unpaid', voucher_status='cancelled')
        _, live = _sale_paid_by(pm, 700.0, at=DAY.replace(hour=11))
        sched = ClearingSettlementScheduler(app)
        assert sched._get_unsettled_ip_ids_up_to(box.id, DAY_END) == [live.id]
        assert sched._get_unsettled_ip_ids_for_day(box.id, DAY, DAY_END) == [live.id]


class TestLivePaymentsAreUnaffected:
    """The guard must change nothing that works today -- measured: every live
    payment in production is paid/unpaid/partially_paid with a non-cancelled
    voucher or no voucher at all."""

    @pytest.mark.parametrize('invoice_status', ['paid', 'partially_paid', 'unpaid'])
    @pytest.mark.parametrize('voucher_status', ['approved', 'pending'])
    def test_standing_payments_are_all_settled(self, app, mada, invoice_status, voucher_status):
        box, pm = mada
        _, ip = _sale_paid_by(pm, 900.0, at=DAY.replace(hour=12),
                              invoice_status=invoice_status, voucher_status=voucher_status)
        sched = ClearingSettlementScheduler(app)
        assert sched._get_unsettled_ip_ids_up_to(box.id, DAY_END) == [ip.id]
        assert sched._get_unsettled_ip_ids_for_day(box.id, DAY, DAY_END) == [ip.id]

    def test_a_payment_without_any_voucher_is_still_settled(self, app, mada):
        """source_voucher_id NULL: deferred payments and rows predating the
        column. The voucher rule cannot see them, so it must not drop them."""
        box, pm = mada
        _, ip = _sale_paid_by(pm, 300.0, at=DAY.replace(hour=13), with_voucher=False)
        sched = ClearingSettlementScheduler(app)
        assert sched._get_unsettled_ip_ids_up_to(box.id, DAY_END) == [ip.id]
        assert sched._get_unsettled_ip_ids_for_day(box.id, DAY, DAY_END) == [ip.id]
