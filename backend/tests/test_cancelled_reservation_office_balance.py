"""A cancelled reservation leaves the office's balance as its books say (RESERVATION-BALANCE-1).

The office's balance, its ledger and its statement left out every entry naming
a cancelled reservation: «a cancelled reservation has no financial impact».
Its execution names it; the execution's reversal, when its purchase is
rejected, names the purchase. Left out was the one, kept the other:
RES-...-0040 (27 Oct 2026), executed and undone three times, then cancelled,
showed office 6 30 riyals in our favour its books do not hold -- and
RES-...-0039 its 0.01. The filter came in (April 2026) when a cancellation
reversed nothing; today every execution and every cancellation is reversed
by an entry of its own, and the books are read as they are.

Run:
    python -m pytest tests/test_cancelled_reservation_office_balance.py -v
"""
import json

from sqlalchemy import func

from models import JournalEntry, JournalEntryLine, OfficeReservation, Supplier, Voucher, db
from services.party_live_balances import compute_live_supplier_balances
from tests.test_reservation_deposit_paid_once import (  # noqa: F401 (fixtures)
    app, rollback_after_each, _close_leftover_orders, _reserve_with_deposit, _settle,
)
from tests.test_phase9c_reservation_invoice_payment import _source_sale_invoice_with_open_order


def _books(account_id):
    """What the office's own account says, cash: every standing line on it."""
    return round(db.session.query(
        func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0)
        - func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0))
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .filter(JournalEntryLine.account_id == account_id,
                JournalEntryLine.is_deleted == False, JournalEntry.is_deleted == False)  # noqa: E712
        .scalar(), 2)


def _executed_undone_cancelled(client, auth_headers, times):
    reservation_id, _ = _reserve_with_deposit(client, auth_headers)
    # As on production: every office's account is its supplier's (27 Oct 2026, offices 4-7).
    office = OfficeReservation.query.get(reservation_id).office
    office.supplier.account_id = office.account_category_id
    db.session.commit()
    for i in range(times):
        if i:
            _source_sale_invoice_with_open_order(2.5)
        _settle(client, auth_headers, reservation_id)
        resp = client.post(f'/api/office-reservations/{reservation_id}/unsettle', headers=auth_headers, json={})
        assert resp.status_code == 200, resp.data
    voucher = Voucher.query.filter_by(reference_type='office_reservation', reference_id=reservation_id).one()
    resp = client.post(f'/api/vouchers/{voucher.id}/cancel', headers=auth_headers, json={'reason': 'سند تجريبي'})
    assert resp.status_code == 200, resp.data
    resp = client.post(f'/api/office-reservations/{reservation_id}/cancel', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.data
    db.session.expire_all()
    reservation = OfficeReservation.query.get(reservation_id)
    assert reservation.status == 'cancelled'
    return reservation.office.supplier_id, reservation.office.account_category_id


def test_executed_undone_then_cancelled_the_office_reads_its_books(app, auth_headers):
    client = app.test_client()
    supplier_id, account_id = _executed_undone_cancelled(client, auth_headers, times=3)
    assert _books(account_id) == 0.0, 'each execution reversed, the deposit voucher cancelled'

    balance = compute_live_supplier_balances([Supplier.query.get(supplier_id)])[supplier_id]
    assert round(balance['cash'], 2) == 0.0, 'the office balance'

    ledger = json.loads(client.get(f'/api/suppliers/{supplier_id}/ledger', headers=auth_headers).data)
    assert ledger['summary']['net']['cash'] == 0.0, 'the ledger'
    statement = json.loads(client.get(f'/api/suppliers/{supplier_id}/statement', headers=auth_headers).data)
    assert round(statement['closing_balance_cash'], 2) == 0.0, 'the statement'
    _close_leftover_orders()


def _office_lines(entry_ids, account_id):
    return (JournalEntryLine.query
            .filter(JournalEntryLine.journal_entry_id.in_(entry_ids), JournalEntryLine.account_id == account_id)
            .all())


def test_an_executions_reversal_is_tagged_to_the_office_as_the_execution(app, auth_headers):
    """WGT-2026-00061/63/65 reversed the office's line without its supplier:
    read only because the office's account is its supplier's."""
    client = app.test_client()
    supplier_id, account_id = _executed_undone_cancelled(client, auth_headers, times=1)
    reservation = OfficeReservation.query.filter(OfficeReservation.office.has(supplier_id=supplier_id)).one()
    execution = JournalEntry.query.filter_by(reference_type='office_reservation', reference_id=reservation.id).filter(
        JournalEntry.description.like('تنفيذ حجز ذهب%')).one()
    reversal = JournalEntry.query.filter_by(reference_type='office_reservation_settlement_reversal').filter(
        JournalEntry.description.like(f'%{reservation.reservation_code}%')).one()
    assert {l.supplier_id for l in _office_lines([execution.id], account_id)} == {supplier_id}
    assert {l.supplier_id for l in _office_lines([reversal.id], account_id)} == {supplier_id}
    _close_leftover_orders()


def test_a_cancellations_reversal_is_tagged_as_the_gold_it_sent(app, auth_headers):
    """A reservation made before 1 Oct 2026 sent its gold at creation
    («إرسال ذهب للحجز»); its cancellation reverses that entry, tags and all."""
    from datetime import datetime
    client = app.test_client()
    reservation_id, _ = _reserve_with_deposit(client, auth_headers)
    reservation = OfficeReservation.query.get(reservation_id)
    office = reservation.office
    other = JournalEntryLine.query.filter(JournalEntryLine.account_id != office.account_category_id).first()
    sent = JournalEntry(entry_number=f'WGT-T{reservation_id:06d}', date=datetime(2026, 9, 1), is_posted=True,
                        description=f'إرسال ذهب للحجز {reservation.reservation_code}',
                        reference_type='office_reservation', reference_id=reservation_id)
    db.session.add(sent)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=sent.id, account_id=office.account_category_id,
                         supplier_id=office.supplier_id, debit_21k=2.5),
        JournalEntryLine(journal_entry_id=sent.id, account_id=other.account_id, credit_21k=2.5),
    ])
    db.session.commit()
    voucher = Voucher.query.filter_by(reference_type='office_reservation', reference_id=reservation_id).one()
    assert client.post(f'/api/vouchers/{voucher.id}/cancel', headers=auth_headers,
                       json={'reason': 'سند تجريبي'}).status_code == 200
    resp = client.post(f'/api/office-reservations/{reservation_id}/cancel', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.data
    db.session.expire_all()
    reversal = JournalEntry.query.filter_by(reference_type='office_reservation', reference_id=reservation_id).filter(
        JournalEntry.description.like('إلغاء حجز%')).one()
    lines = _office_lines([reversal.id], office.account_category_id)
    assert [(l.supplier_id, l.credit_21k) for l in lines] == [(office.supplier_id, 2.5)]
    _close_leftover_orders()
