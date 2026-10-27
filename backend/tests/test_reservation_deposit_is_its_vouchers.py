"""A reservation's deposit is what its standing vouchers paid (the owner, 27 Oct 2026: «ابدأ»).

paid_amount was written once, when the reservation was made. Its deposit
voucher cancelled, it still read paid -- on the list and the office's card --
and the cancellation refused it twice: «عليه دفعات» by that number, and
«مرتبط بسند دفع» by any voucher naming it, the cancelled one too. RES-...-0040
(27 Oct 2026, a 10 riyal deposit, its voucher cancelled) could not be
cancelled at all, though it did what the refusal asked.

Run:
    python -m pytest tests/test_reservation_deposit_is_its_vouchers.py -v
"""
import json

from models import OfficeReservation, Voucher, db
from tests.test_reservation_deposit_paid_once import (  # noqa: F401 (fixtures)
    app, rollback_after_each, _close_leftover_orders, _paid_out_of, _reserve_with_deposit,
)


def _deposit_voucher(reservation_id):
    return Voucher.query.filter_by(reference_type='office_reservation', reference_id=reservation_id).one()


def _cancel_voucher(client, auth_headers, voucher_id):
    resp = client.post(f'/api/vouchers/{voucher_id}/cancel', headers=auth_headers, json={'reason': 'سند تجريبي'})
    assert resp.status_code == 200, resp.data


def test_its_voucher_cancelled_the_reservation_reads_unpaid_and_is_cancelled(app, auth_headers):
    client = app.test_client()
    reservation_id, safe_box = _reserve_with_deposit(client, auth_headers)
    _cancel_voucher(client, auth_headers, _deposit_voucher(reservation_id).id)
    db.session.expire_all()
    reservation = OfficeReservation.query.get(reservation_id)
    assert (reservation.paid_amount, reservation.payment_status) == (0.0, 'pending'), 'what its vouchers paid'

    resp = client.post(f'/api/office-reservations/{reservation_id}/cancel', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.data
    db.session.expire_all()
    assert OfficeReservation.query.get(reservation_id).status == 'cancelled'
    assert _paid_out_of(safe_box) == (0.0, 0.0)
    _close_leftover_orders()


def test_a_reservation_written_paid_before_is_cancelled_by_its_vouchers(app, auth_headers):
    """RES-...-0040 as production holds it: its voucher cancelled, paid_amount still 10."""
    client = app.test_client()
    reservation_id, _ = _reserve_with_deposit(client, auth_headers)
    _cancel_voucher(client, auth_headers, _deposit_voucher(reservation_id).id)
    db.session.expire_all()
    reservation = OfficeReservation.query.get(reservation_id)
    reservation.paid_amount, reservation.payment_status = 575.0, 'paid'
    db.session.commit()

    resp = client.post(f'/api/office-reservations/{reservation_id}/cancel', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.data
    db.session.expire_all()
    reservation = OfficeReservation.query.get(reservation_id)
    assert (reservation.status, reservation.paid_amount, reservation.payment_status) == ('cancelled', 0.0, 'pending')
    _close_leftover_orders()


def test_its_voucher_standing_the_cancellation_is_refused_naming_it(app, auth_headers):
    client = app.test_client()
    reservation_id, safe_box = _reserve_with_deposit(client, auth_headers)
    voucher = _deposit_voucher(reservation_id)
    resp = client.post(f'/api/office-reservations/{reservation_id}/cancel', headers=auth_headers, json={})
    assert resp.status_code == 400, resp.data
    body = json.loads(resp.data)
    assert body['error'] == 'reservation_deposit_standing'
    assert voucher.voucher_number in body['message']
    db.session.expire_all()
    assert OfficeReservation.query.get(reservation_id).status != 'cancelled'
    assert _paid_out_of(safe_box) == (575.0, 575.0)
    _close_leftover_orders()


def test_executed_undone_then_cancelled_its_gold_is_reversed_once(app, auth_headers):
    """The cancellation reversed the first weight entry naming the reservation
    -- its execution's, already reversed by «إلغاء التنفيذ» -- and took its
    gold out of the office's deposit a second time (RES-...-0039, 27 Oct 2026:
    WGT-2026-00059). Only a weight entry written at its creation, before 1 Oct
    2026 («إرسال ذهب للحجز»), is the cancellation's to reverse."""
    from sqlalchemy import and_, func, or_
    from models import Invoice, JournalEntry, JournalEntryLine
    from tests.test_reservation_deposit_paid_once import _settle
    client = app.test_client()
    reservation_id, _ = _reserve_with_deposit(client, auth_headers)
    invoice_id = _settle(client, auth_headers, reservation_id)
    resp = client.post(f'/api/office-reservations/{reservation_id}/unsettle', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.data
    _cancel_voucher(client, auth_headers, _deposit_voucher(reservation_id).id)
    resp = client.post(f'/api/office-reservations/{reservation_id}/cancel', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.data
    db.session.expire_all()

    entries = JournalEntry.query.filter(JournalEntry.is_deleted == False, or_(  # noqa: E712
        and_(JournalEntry.reference_type == 'office_reservation', JournalEntry.reference_id == reservation_id),
        and_(JournalEntry.reference_type == 'office_reservation_settlement_reversal',
             JournalEntry.reference_id == invoice_id)))
    ids = [e.id for e in entries]
    grams = sum((getattr(JournalEntryLine, f'debit_{k}') - getattr(JournalEntryLine, f'credit_{k}')
                 for k in ('18k', '21k', '22k', '24k')))
    net = dict(db.session.query(JournalEntryLine.account_id, func.sum(grams))
               .filter(JournalEntryLine.journal_entry_id.in_(ids), JournalEntryLine.is_deleted == False)  # noqa: E712
               .group_by(JournalEntryLine.account_id).all())
    assert any(e.description.startswith('تنفيذ حجز') for e in entries), 'its gold was bought'
    assert {a: round(v or 0.0, 6) for a, v in net.items() if round(v or 0.0, 6)} == {}, 'the gold back where it was'
    assert Invoice.query.get(invoice_id) is None or Invoice.query.get(invoice_id).status == 'rejected'
    _close_leftover_orders()
