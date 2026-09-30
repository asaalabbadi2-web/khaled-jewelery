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
from clearing_settlement_scheduler import (
    ClearingSettlementScheduler,
    settleable_payments_query,
)
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
def rollback_after_each(app, db_fence):
    yield


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


class TestAmountAndPaymentsComeFromOneRule:
    """The invariant the first version of this fix broke.

    The per-day run takes its AMOUNT from _compute_due_for_day and its PAYMENTS
    from _get_unsettled_ip_ids_for_day. The first fix corrected the second and
    missed the first -- 30 lines away in the same file -- so after AV-2026-00436
    was reversed in production the scheduler computed 6,530.00 due, selected
    4,380.00 of payments, and refused to settle at all
    ('no_days_had_due_amount'). Safe, but Sep 26 was left unsettled.

    Testing each selector alone could not see that. This asserts the agreement.
    """

    def _replay(self, pm):
        _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=42),
                      invoice_status='rejected', voucher_status='pending')
        _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=49))
        _sale_paid_by(pm, 1000.0, at=DAY.replace(hour=15, minute=35))
        _sale_paid_by(pm, 1230.0, at=DAY.replace(hour=15, minute=46))

    def test_day_amount_equals_the_payments_it_will_settle(self, app, mada):
        box, pm = mada
        self._replay(pm)
        sched = ClearingSettlementScheduler(app)
        amount = sched._compute_due_for_day(box.id, DAY, DAY_END)
        payments = _amounts(sched._get_unsettled_ip_ids_for_day(box.id, DAY, DAY_END))
        assert amount == payments == 4380.0

    def test_agreement_holds_for_live_payments_too(self, app, mada):
        box, pm = mada
        _sale_paid_by(pm, 900.0, at=DAY.replace(hour=12))
        _sale_paid_by(pm, 300.0, at=DAY.replace(hour=13), with_voucher=False)
        sched = ClearingSettlementScheduler(app)
        assert sched._compute_due_for_day(box.id, DAY, DAY_END) == \
            _amounts(sched._get_unsettled_ip_ids_for_day(box.id, DAY, DAY_END)) == 1200.0


class TestThePendingScreenAndManualSettlement:
    """The settlement screen had its own copy of the selection: after the
    reversal it listed 3123's dead 2,150.00 next to 3124's, and a manual
    settlement accepted whatever payment ids the user ticked."""

    def test_pending_list_does_not_offer_a_dead_payment(self, app, mada):
        box, pm = mada
        _, dead = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=42),
                                invoice_status='rejected', voucher_status='pending')
        _, live = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=49))
        from routes.clearing import _settleable_ip_ids_for_box
        ids = _settleable_ip_ids_for_box(box.id)
        assert dead.id not in ids and live.id in ids

    def test_manual_settlement_refuses_a_dead_payment(self, app, mada):
        box, pm = mada
        _, dead = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=42),
                                invoice_status='rejected', voucher_status='pending')
        _, live = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=49))
        from routes.clearing import _refuse_unsettleable_payment_ids
        refused = _refuse_unsettleable_payment_ids(box.id, [dead.id, live.id])
        assert refused == [dead.id]
        assert _refuse_unsettleable_payment_ids(box.id, [live.id]) == []

    def test_per_transaction_settlement_skips_a_retracted_invoice(self, app, mada):
        """The legacy per-transaction path selects SafeBoxTransaction rows, not
        InvoicePayment, so it gets the invoice rule only (the known gap)."""
        from models import SafeBoxTransaction
        from routes.clearing import _unsettled_invoice_payment_sbts
        box, pm = mada
        dead_inv, dead_ip = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=42),
                                          invoice_status='rejected', voucher_status='pending')
        live_inv, live_ip = _sale_paid_by(pm, 2150.0, at=DAY.replace(hour=8, minute=49))
        # As in production for 3123: ref_id is the receipt voucher, and the model
        # requires the invoice_payment link on every invoice_payment movement.
        for inv, ip in ((dead_inv, dead_ip), (live_inv, live_ip)):
            # The receipt voucher names its payment, as production's do; on SQLite
            # the voucher and payment ids happened to coincide and hid its absence.
            import json
            Voucher.query.get(ip.source_voucher_id).notes = json.dumps({'invoice_payment_id': ip.id})
            db.session.flush()
            db.session.add(SafeBoxTransaction(
                safe_box_id=box.id, ref_type='invoice_payment', ref_id=ip.source_voucher_id,
                invoice_id=inv.id, invoice_payment_id=ip.id, direction='in',
                amount_cash=2150.0, created_at=inv.date, created_by='t'))
        db.session.flush()
        got = {t.invoice_id for t in _unsettled_invoice_payment_sbts(box.id)}
        assert dead_inv.id not in got and live_inv.id in got


# ======================================================================
# THE FOURTH READER — the due balance the screen shows
#
# fe8ffc6 unified the settleable rule across three readers and its docstring
# says "EVERY selection of settleable payments starts here". A fourth was
# missed, in another file: routes/clearing.py::_compute_clearing_due_amount,
# which selected ALL InvoicePayments of the box by payment method alone.
#
# Measured on the 28 Sep 09:48 production snapshot (safe box 32, Mada):
#     due balance shown   5,940.00
#     should be           3,790.00
#     difference          2,150.00   = rejected invoice 3123's payment, exactly
#
# Reported by the user from the screen: "رصيد التسوية المستحق لا زال يقرأها".
# ======================================================================

class TestTheDueBalanceUsesTheSameRule:

    def _replay(self, pm):
        return TestIncident3123()._replay(pm)

    def test_the_due_balance_excludes_a_retracted_invoice_payment(self, app, mada):
        """The screen's figure. A rejected invoice's payment is not money waiting
        to be settled — it is money that never stood."""
        from routes.clearing import _compute_clearing_due_amount

        box, pm = mada
        dead, live = self._replay(pm)

        assert _compute_clearing_due_amount(box.id) == 4380.0, (
            'due balance must equal the live payments only — the rejected '
            "invoice's 2,150 was being counted as pending"
        )

    def test_the_due_balance_excludes_a_cancelled_voucher_payment(self, app, mada):
        from routes.clearing import _compute_clearing_due_amount

        box, pm = mada
        _sale_paid_by(pm, 700.0, at=DAY.replace(hour=10), voucher_status='cancelled')
        _, live = _sale_paid_by(pm, 300.0, at=DAY.replace(hour=11))

        assert _compute_clearing_due_amount(box.id) == 300.0

    def test_the_due_balance_agrees_with_the_payments_it_would_settle(self, app, mada):
        """The agreement that makes 'no_days_had_due_amount' impossible: the
        figure on the screen and the payments behind it come from one rule."""
        from routes.clearing import _compute_clearing_due_amount

        box, pm = mada
        dead, live = self._replay(pm)
        settleable = {ip.id for ip in settleable_payments_query(box.id).all()}

        assert dead.id not in settleable
        assert _compute_clearing_due_amount(box.id) == _amounts(settleable)


class TestNoFifthSettleableReader:
    """THE RATCHET. Three readers were fixed, then a fourth was found in another
    file. Selecting InvoicePayments by a safe box's payment method is the
    signature of a settleable-payments reader, and it may only happen inside
    settleable_payments_query()."""

    # (file, enclosing function) -> why it may select every payment of a box.
    # Keyed on the FUNCTION, not the file, so a new reader added next to one of
    # these is still caught.
    ALLOWED = {
        ('clearing_settlement_scheduler.py', 'settleable_payments_query'):
            'the unified rule itself',
        ('payment_methods_routes.py', 'update_payment_method'):
            'a duplicate check joining PaymentMethod to SafeBox; selects no payments',
        ('routes/safe_boxes.py', 'delete_safe_box'):
            'counts payment methods linked to a box before deleting it; selects no payments',
        # ── KNOWN DEBT — same defect class, deliberately not changed here ────
        # Each selects every payment of the box, dead ones included. They are
        # manual admin tools, and changing a repair tool's selection without
        # re-deriving what it repairs could break the repair itself. Recorded
        # so they are visible and so this ratchet still fails on a NEW reader.
        ('routes/admin.py', 'clearing_gap_report'):
            'DEBT: reports a rejected invoice payment as a "true gap" (false alarm)',
        ('allocation_repair_service.py', 'repair_safe_box'):
            'DEBT: could allocate settlement to a dead payment if run',
        ('routes/admin.py', 'repair_voucher_date_bounded'):
            'DEBT: could allocate settlement to a dead payment if run',
    }

    def test_only_the_unified_rule_selects_payments_by_clearing_box(self):
        import ast
        import re
        from pathlib import Path

        backend = Path(__file__).resolve().parent.parent
        signature = re.compile(r'default_safe_box_id\s*==')
        offenders = []
        for path in backend.rglob('*.py'):
            rel = path.relative_to(backend).as_posix()
            if rel.startswith(('venv/', 'devtools/', 'tools/', 'tests/', 'alembic/')) \
                    or rel.startswith('test_'):
                continue
            src = path.read_text(encoding='utf-8', errors='ignore')
            if 'default_safe_box_id' not in src:
                continue
            try:
                tree = ast.parse(src)
            except SyntaxError:
                continue
            spans = [
                (n.lineno, getattr(n, 'end_lineno', n.lineno), n.name)
                for n in ast.walk(tree)
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
            ]
            for line_no, line in enumerate(src.splitlines(), 1):
                if not signature.search(line.split('#', 1)[0]):
                    continue
                enclosing = [s for s in spans if s[0] <= line_no <= s[1]]
                fn = min(enclosing, key=lambda s: s[1] - s[0])[2] if enclosing else '<module>'
                if (rel, fn) not in self.ALLOWED:
                    offenders.append(f'{rel}:{line_no} in {fn}(): {line.strip()}')
        assert not offenders, (
            'select settleable payments through settleable_payments_query(); a '
            'parallel copy is how the due balance kept counting invoice 3123:\n  '
            + '\n  '.join(offenders)
        )

    def test_the_allowlist_has_no_stale_entries(self):
        """A debt entry whose function no longer matches means the debt was paid
        (or the code moved) — the entry must be removed, not left to excuse a
        future reader of the same name."""
        import ast
        import re
        from pathlib import Path

        backend = Path(__file__).resolve().parent.parent
        signature = re.compile(r'default_safe_box_id\s*==')
        stale = []
        for (rel, fn), _why in self.ALLOWED.items():
            src = (backend / rel).read_text(encoding='utf-8', errors='ignore')
            tree = ast.parse(src)
            node = next((n for n in ast.walk(tree)
                         if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
                         and n.name == fn), None)
            body = ast.get_source_segment(src, node) if node else ''
            if not node or not signature.search(body or ''):
                stale.append(f'{rel}::{fn}')
        assert not stale, 'remove paid-off entries: ' + ', '.join(stale)
