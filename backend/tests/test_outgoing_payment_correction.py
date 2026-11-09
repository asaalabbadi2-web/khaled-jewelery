"""A payment's method corrected the way the money went (production, 8 Nov 2026).

«تصحيح وسيلة الدفع» wrote «credit the old safe, debit the new» whatever the
payment -- right for money received (a sale), backwards for money paid out (a
purchase): 494.5 paid the Dewan from the cash box, put right to the bank,
credited the cash box AGAIN and debited the bank (JE-2026-07425) -- the
books 989 off in both, the safe rows right (SAFEBOX_SUBLEDGER_DRIFT, ±989).
Its split's new safe row was «in» whatever the payment too.

The payment says its own direction -- its safe row, or the side of its
voucher's entry on the old safe -- and the correction follows it: money
paid out goes back to the old safe (debit) and out of the new one (credit).

Run:
    python -m pytest tests/test_outgoing_payment_correction.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import Account, InvoicePayment, JournalEntryLine, PaymentMethod, SafeBox, SafeBoxTransaction, db
from tests.test_supplier_purchase_effect import SHAPES, _vat, app, rollback_after_each, world  # noqa: F401


def _uid():
    return uuid.uuid4().hex[:6]


def _safe(kind):
    acc = Account(account_number=f'11{uuid.uuid4().int % 10**6:06d}', name=f'{kind} {_uid()}', type='Asset',
                  transaction_type='cash', tracks_weight=False)
    db.session.add(acc)
    db.session.flush()
    box = SafeBox(name=f'{kind} {_uid()}', safe_type=kind, account_id=acc.id, is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(name=f'{kind} {_uid()}', payment_type=kind, default_safe_box_id=box.id)
    db.session.add(pm)
    db.session.flush()
    return box, pm


def _cash(account_id):
    rows = JournalEntryLine.query.filter_by(account_id=account_id, is_deleted=False).all()
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in rows), 2)


def _rows(box):
    rows = SafeBoxTransaction.query.filter_by(safe_box_id=box.id).all()
    return round(sum(float(r.amount_cash or 0) * (1 if r.direction == 'in' else -1) for r in rows), 2)


@pytest.fixture
def paid(auth_headers, world):
    cash, cash_pm = _safe('cash')
    bank, bank_pm = _safe('bank')
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload.update(settlement_method='partial', amount_paid=1000.0, wage_subtotal=1000.0, wage_cash=1000.0,
                   payments=[{'payment_method_id': cash_pm.id, 'amount': 1000.0}])
    r = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=payload)
    assert r.status_code == 201, r.get_data(as_text=True)[:400]
    invoice_id = r.get_json()['id']
    payment = InvoicePayment.query.filter_by(invoice_id=invoice_id).one()
    assert (_cash(cash.account_id), _rows(cash)) == (-1000.0, -1000.0), 'paid out of the cash box'
    return {'invoice_id': invoice_id, 'payment': payment, 'cash': cash, 'bank': bank, 'bank_pm': bank_pm,
            'cash_pm': cash_pm}


def _correct(headers, p, **body):
    r = flask_app.test_client().post(f"/api/invoices/{p['invoice_id']}/payments/{p['payment'].id}/correct-method",
                                     headers=headers, json={'reason': 'دُفعت تحويلًا', **body})
    assert r.status_code == 200, r.get_data(as_text=True)[:400]


def test_paid_out_and_put_right_in_full(auth_headers, paid):
    _correct(auth_headers, paid, new_payment_method_id=paid['bank_pm'].id)
    cash, bank = paid['cash'], paid['bank']
    assert (_cash(cash.account_id), _cash(bank.account_id)) == (0.0, -1000.0), 'out of the bank, not the cash box'
    assert (_rows(cash), _rows(bank)) == (0.0, -1000.0), 'the books and the safe rows agree'


def test_paid_out_and_put_right_in_part(auth_headers, paid):
    _correct(auth_headers, paid, new_payment_method_id=paid['bank_pm'].id, correction_amount=400.0)
    cash, bank = paid['cash'], paid['bank']
    assert (_cash(cash.account_id), _cash(bank.account_id)) == (-600.0, -400.0)
    assert (_rows(cash), _rows(bank)) == (-600.0, -400.0), 'the split\'s row goes out, as its payment did'


def test_paid_out_and_split_across_methods(auth_headers, paid):
    other, other_pm = _safe('bank')
    _correct(auth_headers, paid, splits=[{'payment_method_id': paid['bank_pm'].id, 'amount': 700.0},
                                         {'payment_method_id': other_pm.id, 'amount': 300.0}])
    cash, bank = paid['cash'], paid['bank']
    assert (_cash(cash.account_id), _cash(bank.account_id), _cash(other.account_id)) == (0.0, -700.0, -300.0)
    assert (_rows(cash), _rows(bank), _rows(other)) == (0.0, -700.0, -300.0)


def _payment(paid, amount, *, row_direction=None):
    ip = InvoicePayment(invoice_id=paid['invoice_id'], payment_method_id=paid['cash_pm'].id, amount=amount,
                       net_amount=amount)
    db.session.add(ip)
    db.session.flush()
    if row_direction:
        db.session.add(SafeBoxTransaction(safe_box_id=paid['cash'].id, ref_type='invoice_payment', ref_id=ip.id,
                                          invoice_id=paid['invoice_id'], invoice_payment_id=ip.id,
                                          payment_method_id=paid['cash_pm'].id, direction=row_direction,
                                          amount_cash=amount, created_by='t'))
        db.session.flush()
    return ip


def test_money_received_is_put_right_as_it_always_was(auth_headers, paid):
    """Credit the old safe, debit the new -- the sale's case, unchanged."""
    ip = _payment(paid, 500.0, row_direction='in')
    cash, bank = paid['cash'], paid['bank']
    before = (_cash(cash.account_id), _cash(bank.account_id))
    _correct(auth_headers, {**paid, 'payment': ip}, new_payment_method_id=paid['bank_pm'].id)
    after = (_cash(cash.account_id), _cash(bank.account_id))
    assert (round(after[0] - before[0], 2), round(after[1] - before[1], 2)) == (-500.0, 500.0)


def test_a_payment_that_does_not_say_its_direction_is_not_guessed(auth_headers, paid):
    ip = _payment(paid, 300.0)                     # no safe row, no voucher
    r = flask_app.test_client().post(f"/api/invoices/{paid['invoice_id']}/payments/{ip.id}/correct-method",
                                     headers=auth_headers,
                                     json={'reason': 'x', 'new_payment_method_id': paid['bank_pm'].id})
    assert r.status_code == 400 and r.get_json()['error'] == 'payment_direction_unknown', r.get_data(as_text=True)
