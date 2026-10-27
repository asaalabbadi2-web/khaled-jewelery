"""A reservation's deposit leaves the safe once, however its purchase is posted.

The deposit is paid by its voucher when the reservation is made: the voucher's
entry credits the safe and its safe row says so. Executed, the reservation
shows the deposit on its purchase as a payment linked to that voucher (Phase
9C), and the execution approves the purchase (ADR-052). The approval wrote an
entry and a safe row for every payment it found, the voucher's own among them:
on production, reservation RES-...-0038 (26 Oct 2026) paid its 53,123.62 out
of the main cash twice -- PV-2026-01419 and PAY-3501-ALL -- and RES-...-0032
(21 Sep) its 0.05. The owner cancelled the voucher to undo the second.

A payment carried by its own voucher is in the books already: posting writes
it no entry and no safe row.

Run:
    python -m pytest tests/test_reservation_deposit_paid_once.py -v
"""
import json

from sqlalchemy import func

from models import Invoice, JournalEntry, JournalEntryLine, SafeBoxTransaction, WeightClosingOrder, db
from tests.test_phase9c_reservation_invoice_payment import (  # noqa: F401 (fixtures)
    app, rollback_after_each, _ensure_purchases_account, _office_and_supplier, _payment_method,
    _safe_box_with_account, _source_sale_invoice_with_open_order,
)


def _paid_out_of(safe_box):
    """What the books and the safe's statement say left the safe."""
    credit = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0)
                               - func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0))
              .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
              .filter(JournalEntryLine.account_id == safe_box.account_id,
                      JournalEntryLine.is_deleted == False, JournalEntry.is_deleted == False)  # noqa: E712
              .scalar())
    rows = SafeBoxTransaction.query.filter_by(safe_box_id=safe_box.id).all()
    statement = sum(r.amount_cash for r in rows if r.direction == 'out') - sum(
        r.amount_cash for r in rows if r.direction == 'in')
    return round(credit, 2), round(statement, 2)


def _reserve_with_deposit(client, auth_headers):
    _ensure_purchases_account()
    office = _office_and_supplier()
    safe_box = _safe_box_with_account()
    pm = _payment_method(safe_box.id)
    _source_sale_invoice_with_open_order(2.5)
    resp = client.post('/api/office-reservations', headers=auth_headers, json={
        'office_id': office.id, 'weight': 2.5, 'price_per_gram': 230.0,
        'execution_price_per_gram': 230.0, 'paid_amount': 575.0, 'payment_method_id': pm.id,
    })
    assert resp.status_code == 201, resp.data
    return json.loads(resp.data)['id'], safe_box


def _settle(client, auth_headers, reservation_id):
    resp = client.post(f'/api/office-reservations/{reservation_id}/settle', headers=auth_headers,
                       json={'execution_price_per_gram': 230.0})
    assert resp.status_code == 200, resp.data
    return json.loads(resp.data)['purchase_invoice_id']


def _close_leftover_orders():
    # The weight-closing pool is global; see test_phase9c's note.
    db.session.expire_all()
    WeightClosingOrder.query.filter(WeightClosingOrder.status.in_(['open', 'partially_closed'])).update(
        {'status': 'closed'}, synchronize_session=False)
    db.session.commit()


def test_an_executed_reservation_pays_its_deposit_once(app, auth_headers):
    client = app.test_client()
    reservation_id, safe_box = _reserve_with_deposit(client, auth_headers)
    assert _paid_out_of(safe_box) == (575.0, 575.0), 'the deposit voucher paid it'

    invoice_id = _settle(client, auth_headers, reservation_id)
    db.session.expire_all()
    assert _paid_out_of(safe_box) == (575.0, 575.0), 'executing the reservation pays nothing again'
    assert JournalEntry.query.filter_by(reference_type='invoice_payments', reference_id=invoice_id,
                                        is_deleted=False).count() == 0
    invoice = Invoice.query.get(invoice_id)
    assert (invoice.status, invoice.amount_paid) == ('paid', 575.0)
    _close_leftover_orders()


def test_undone_and_executed_again_it_still_paid_once(app, auth_headers):
    client = app.test_client()
    reservation_id, safe_box = _reserve_with_deposit(client, auth_headers)
    _settle(client, auth_headers, reservation_id)
    resp = client.post(f'/api/office-reservations/{reservation_id}/unsettle', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.data
    _source_sale_invoice_with_open_order(2.5)
    invoice_id = _settle(client, auth_headers, reservation_id)
    db.session.expire_all()
    assert _paid_out_of(safe_box) == (575.0, 575.0)
    assert Invoice.query.get(invoice_id).status == 'paid'
    _close_leftover_orders()
