"""A voucher's cancellation reverses its own safe rows, not a row whose id coincides (VOUCHER-CANCEL-SAFE-1).

routes/vouchers._append_safe_reversal_transactions_for_voucher takes the rows
of type 'voucher' or 'invoice_payment' whose ref_id is the voucher's id. An
'invoice_payment' row's ref_id is its payment's id: a payment linked to the
voucher whose id happens to equal the voucher's is taken for the voucher's
own, and reversed with it while the ledger reverses only the voucher's entry.
Seen while repairing a deposit paid twice (27 Oct 2026): on a fresh database
the deposit voucher and its payment were both 1, and cancelling the voucher
put 1,150 back in the safe's statement against 575 in its ledger. None on the
27 Oct production copy.

Run:
    python -m pytest tests/test_voucher_cancel_reverses_its_own_safe_rows.py -v
"""
import pytest
from sqlalchemy import text

import posting_routes
from models import InvoicePayment, Voucher, db
from tests.test_reservation_deposit_paid_once import (  # noqa: F401 (fixtures)
    app, rollback_after_each, _close_leftover_orders, _paid_out_of, _reserve_with_deposit, _settle,
)


def _sequence_past_both():
    db.session.execute(text(
        "select setval(pg_get_serial_sequence('voucher', 'id'), greatest("
        "(select coalesce(max(id), 0) from voucher), (select coalesce(max(id), 0) from invoice_payment)) + 1000)"))


@pytest.mark.xfail(strict=True, reason='VOUCHER-CANCEL-SAFE-1: rows matched by ref_id, not by the entry they were '
                                       'written for')
def test_a_payment_whose_id_is_its_voucher_s_keeps_its_row(app, auth_headers, monkeypatch):
    client = app.test_client()
    _sequence_past_both()
    reservation_id, safe_box = _reserve_with_deposit(client, auth_headers)
    voucher = Voucher.query.filter(Voucher.description.like('%عربون%')).order_by(Voucher.id.desc()).first()
    # The next payment row takes the voucher's id.
    db.session.execute(text("select setval(pg_get_serial_sequence('invoice_payment', 'id'), :v - 1)"),
                       {'v': voucher.id})
    with monkeypatch.context() as m:   # the deposit paid twice, as before its fix
        m.setattr(posting_routes, '_carried_by_its_voucher', lambda pay: False)
        invoice_id = _settle(client, auth_headers, reservation_id)
    assert InvoicePayment.query.filter_by(invoice_id=invoice_id).one().id == voucher.id

    resp = client.post(f'/api/vouchers/{voucher.id}/cancel', headers=auth_headers, json={'reason': 'تكرار'})
    assert resp.status_code == 200, resp.data
    db.session.expire_all()
    try:
        ledger, statement = _paid_out_of(safe_box)
        assert statement == ledger == 575.0
    finally:
        _close_leftover_orders()
