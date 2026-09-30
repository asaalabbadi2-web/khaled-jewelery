"""Unposting a sales invoice must give back ALL the gold it moved out.

INCIDENT, 2026-09-26: sales invoice 3123 (3.3 g of 22k from the display box)
was unposted from the posting screen and rejected; its replacement 3124 moved
the same 3.3 g out. The box's movement statement then showed 6.6 g gone for
3.3 g actually sold.

ROOT CAUSE: posting_routes._append_safe_reversal_transactions_for_invoice_gold
nets invoice_gold against invoice_gold_reversal and reverses the remainder --
and never looks at invoice_sale_gold_movement, the movement a sale writes when
it is created. Worse, it opens with `if not all_gold: return []`, so an
ordinary sale -- which carries ONLY invoice_sale_gold_movement -- is not
reversed at all. Measured on the post-incident production copy: 1,440
invoice_sale_gold_movement rows against 166 invoice_gold rows. The branch that
worked was the rare one.

THE FIX reverses a sale movement with the SAME ref_type in the opposite
direction (precedent: 4 such 'in' rows already exist in production), leaving
the invoice_gold / invoice_gold_reversal pairing untouched -- the posting
writer (_append_safe_transactions_for_invoice_gold) reads exactly that pair to
decide whether a re-post must write gold again, so it must not change meaning.

BLAST RADIUS, measured: one retracted invoice in all of production carries
leftover gold movements -- 3123. TestInvoiceGoldOnlyIsUnchanged holds that the
path which already worked still behaves byte for byte the same.

Run:
    python -m pytest tests/test_unpost_reverses_sale_gold_movement.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, SafeBox, SafeBoxTransaction, db
from posting_routes import _append_safe_reversal_transactions_for_invoice_gold


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
def display_box(app):
    acc = Account(account_number=f'7{_uid()[:5]}', name=f'معروض {_uid()}', type='Asset')
    db.session.add(acc)
    db.session.flush()
    now = datetime.now()
    box = SafeBox(name=f'معروض {_uid()}', safe_type='gold', account_id=acc.id,
                  is_active=True, is_default=False, created_at=now, updated_at=now)
    db.session.add(box)
    db.session.flush()
    return box


def _sale(weight=3.3):
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع',
                  date=datetime.now(), total=2150.0, total_weight=weight,
                  status='paid', amount_paid=0.0, is_posted=False)
    db.session.add(inv)
    db.session.flush()
    return inv


def _move(box, inv, ref_type, direction, *, w22=0.0, w21=0.0):
    t = SafeBoxTransaction(
        safe_box_id=box.id, ref_type=ref_type, ref_id=inv.id, invoice_id=inv.id,
        direction=direction, amount_cash=0.0,
        weight_18k=0.0, weight_21k=w21, weight_22k=w22, weight_24k=0.0,
        created_at=datetime.now(), created_by='t')
    db.session.add(t)
    db.session.flush()
    return t


def _net_gold(box, inv):
    """Signed grams of this invoice in *box*, every movement type counted."""
    total = 0.0
    for t in SafeBoxTransaction.query.filter_by(safe_box_id=box.id, invoice_id=inv.id).all():
        grams = sum(float(getattr(t, f'weight_{k}k') or 0) for k in (18, 21, 22, 24))
        total += grams if t.direction == 'in' else -grams
    return round(total, 6)


class TestIncident3123:
    def test_the_leftover_sale_movement_is_given_back(self, app, display_box):
        """3123's exact state before the fix: sale movement out, invoice_gold
        out, invoice_gold reversed -- 3.3 g still counted as gone."""
        inv = _sale()
        _move(display_box, inv, 'invoice_sale_gold_movement', 'out', w22=3.3)
        _move(display_box, inv, 'invoice_gold', 'out', w22=3.3)
        _move(display_box, inv, 'invoice_gold_reversal', 'in', w22=3.3)
        assert _net_gold(display_box, inv) == -3.3

        _append_safe_reversal_transactions_for_invoice_gold(inv)
        db.session.flush()

        assert _net_gold(display_box, inv) == 0.0


class TestAnOrdinarySale:
    def test_a_sale_with_only_its_sale_movement_is_reversed(self, app, display_box):
        """The common case -- and the one the early `return []` skipped."""
        inv = _sale(weight=10.0)
        _move(display_box, inv, 'invoice_sale_gold_movement', 'out', w21=10.0)

        created = _append_safe_reversal_transactions_for_invoice_gold(inv)
        db.session.flush()

        assert _net_gold(display_box, inv) == 0.0
        assert [(c.ref_type, c.direction) for c in created] == \
            [('invoice_sale_gold_movement', 'in')]

    def test_running_it_twice_writes_nothing_the_second_time(self, app, display_box):
        inv = _sale(weight=10.0)
        _move(display_box, inv, 'invoice_sale_gold_movement', 'out', w21=10.0)
        _append_safe_reversal_transactions_for_invoice_gold(inv)
        db.session.flush()

        assert _append_safe_reversal_transactions_for_invoice_gold(inv) == []
        assert _net_gold(display_box, inv) == 0.0


class TestInvoiceGoldOnlyIsUnchanged:
    """The branch that already worked must behave exactly as before: an
    invoice_gold movement is reversed by one invoice_gold_reversal row."""

    def test_invoice_gold_is_still_reversed_with_its_own_type(self, app, display_box):
        inv = _sale(weight=5.0)
        _move(display_box, inv, 'invoice_gold', 'in', w21=5.0)

        created = _append_safe_reversal_transactions_for_invoice_gold(inv)
        db.session.flush()

        assert [(c.ref_type, c.direction) for c in created] == \
            [('invoice_gold_reversal', 'out')]
        assert _net_gold(display_box, inv) == 0.0

    def test_nothing_to_reverse_writes_nothing(self, app, display_box):
        inv = _sale()
        assert _append_safe_reversal_transactions_for_invoice_gold(inv) == []


class TestTheOneOffRepairForRetractedInvoices:
    """tools/maintenance/reverse_retracted_invoice_gold.py applies the fixed
    function to invoices retracted before the fix (3123). Its refusals are what
    keep it from hiding gold that really left the shop."""

    def test_it_repairs_a_rejected_sale(self, app, display_box):
        from tools.maintenance.reverse_retracted_invoice_gold import reverse_for_invoice
        inv = _sale()
        inv.status = 'rejected'
        _move(display_box, inv, 'invoice_sale_gold_movement', 'out', w22=3.3)
        reverse_for_invoice(inv.id)
        db.session.flush()
        assert _net_gold(display_box, inv) == 0.0

    def test_it_refuses_a_posted_invoice(self, app, display_box):
        from tools.maintenance.reverse_retracted_invoice_gold import Refused, reverse_for_invoice
        inv = _sale()
        inv.is_posted = True
        inv.status = 'rejected'
        _move(display_box, inv, 'invoice_sale_gold_movement', 'out', w22=3.3)
        with pytest.raises(Refused):
            reverse_for_invoice(inv.id)
        assert _net_gold(display_box, inv) == -3.3

    def test_it_refuses_an_invoice_that_was_not_retracted(self, app, display_box):
        """Unposted but standing (awaiting approval): its sale is real."""
        from tools.maintenance.reverse_retracted_invoice_gold import Refused, reverse_for_invoice
        inv = _sale()
        _move(display_box, inv, 'invoice_sale_gold_movement', 'out', w22=3.3)
        with pytest.raises(Refused):
            reverse_for_invoice(inv.id)
        assert _net_gold(display_box, inv) == -3.3
