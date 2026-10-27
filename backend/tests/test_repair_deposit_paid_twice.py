"""The repair of a deposit its purchase's posting paid again (services/repair/deposit_paid_twice).

The duplicate is made as production made it -- the posting without its guard
(posting_routes._carried_by_its_voucher) -- then set right both ways the 27
Oct backup holds: the voucher standing (RES-...-0032), and the voucher the
owner cancelled (RES-...-0038).

Run:
    python -m pytest tests/test_repair_deposit_paid_twice.py -v
"""
import json
from datetime import datetime

import pytest
from sqlalchemy import text

import posting_routes
from models import Invoice, InvoicePayment, JournalEntry, Voucher, db
from services.repair.deposit_paid_twice import set_deposits_paid_twice_right
from tests.test_reservation_deposit_paid_once import (  # noqa: F401 (fixtures)
    app, rollback_after_each, _close_leftover_orders, _paid_out_of, _reserve_with_deposit, _settle,
)


@pytest.fixture
def paid_twice(app, auth_headers, monkeypatch):
    """A reservation executed as before the fix: its deposit paid twice."""
    client = app.test_client()
    reservation_id, safe_box = _reserve_with_deposit(client, auth_headers)
    # Apart from the voucher's id, as on production (4853 and 3840): on a fresh
    # database both are 1, and a safe row keyed by the payment's id reads as
    # the voucher's own when its cancellation reverses it.
    db.session.execute(text("select setval(pg_get_serial_sequence('invoice_payment', 'id'), "
                            "greatest((select coalesce(max(id), 0) from invoice_payment), 100000))"))
    with monkeypatch.context() as m:
        m.setattr(posting_routes, '_carried_by_its_voucher', lambda pay: False)
        invoice_id = _settle(client, auth_headers, reservation_id)
    db.session.expire_all()
    assert _paid_out_of(safe_box) == (1150.0, 1150.0), 'made as production made it'
    yield client, invoice_id, safe_box
    _close_leftover_orders()


def _mine(plan, invoice_id, key):
    return [c for c in plan[key] if c['invoice_id'] == invoice_id]


def test_the_voucher_standing_the_second_payment_is_reversed(paid_twice):
    client, invoice_id, safe_box = paid_twice
    plan = set_deposits_paid_twice_right(by='test', now=datetime.now(), dry_run=True)
    assert len(_mine(plan, invoice_id, 'reversed')) == 1
    assert _paid_out_of(safe_box) == (1150.0, 1150.0), 'a dry run writes nothing'

    # The safe here is no protected account: its reversal comes back to it.
    plan = set_deposits_paid_twice_right(by='test', now=datetime.now(), dry_run=False)
    assert _mine(plan, invoice_id, 'reversed')[0]['reversal']
    db.session.expire_all()
    assert _paid_out_of(safe_box) == (575.0, 575.0)
    invoice = Invoice.query.get(invoice_id)
    assert (invoice.status, invoice.amount_paid) == ('paid', 575.0)
    again = set_deposits_paid_twice_right(by='test', now=datetime.now(), dry_run=False)
    assert not _mine(again, invoice_id, 'reversed'), 'once'


def test_the_voucher_cancelled_the_payment_is_carried_by_the_posting_s_entry(paid_twice, auth_headers):
    client, invoice_id, safe_box = paid_twice
    deposit = InvoicePayment.query.filter_by(invoice_id=invoice_id).one()
    cancelled = Voucher.query.get(deposit.source_voucher_id)
    resp = client.post(f'/api/vouchers/{cancelled.id}/cancel', headers=auth_headers,
                       json={'reason': 'تكرار سداد الفاتورة'})
    assert resp.status_code == 200, resp.data
    db.session.expire_all()
    assert _paid_out_of(safe_box) == (575.0, 575.0), 'the owner undid the second payment'
    assert Invoice.query.get(invoice_id).status == 'unpaid', 'as production reads 3501'

    plan = set_deposits_paid_twice_right(by='test', now=datetime.now(), dry_run=False)
    case = _mine(plan, invoice_id, 'relinked')[0]
    db.session.expire_all()
    assert _paid_out_of(safe_box) == (575.0, 575.0), 'no amount moves'
    invoice = Invoice.query.get(invoice_id)
    assert (invoice.status, invoice.amount_paid) == ('paid', 575.0)
    deposit = InvoicePayment.query.filter_by(invoice_id=invoice_id).one()
    new = Voucher.query.get(deposit.source_voucher_id)
    posting = JournalEntry.query.filter_by(reference_type='invoice_payments', reference_id=invoice_id).one()
    assert (new.voucher_number, new.status, new.journal_entry_id) == (case['new_voucher'], 'approved', posting.id)
    assert Voucher.query.get(cancelled.id).status == 'cancelled', 'the cancelled voucher stays as it is'
    again = set_deposits_paid_twice_right(by='test', now=datetime.now(), dry_run=False)
    assert not _mine(again, invoice_id, 'relinked'), 'once'
