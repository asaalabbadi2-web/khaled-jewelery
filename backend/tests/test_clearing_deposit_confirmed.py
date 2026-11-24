"""A deposit is confirmed by what reached the bank (ADR-100).

The settlement books what it computes on the day the deposit is due; the bank
says what came. The accountant enters it, and the difference is posted, dated
the deposit's day, between the bank and the commission and its VAT. A
settlement is confirmed once; a confirmed one is not cancelled under its
deposit; a difference beyond the method's allowance needs a note; the
difference's voucher cancelled, the settlements are unconfirmed again.

Run:
    python -m pytest tests/test_clearing_deposit_confirmed.py -v
"""
import uuid
from datetime import date, datetime

import pytest
from flask import g
from sqlalchemy import func

from app import app as flask_app
from models import (Account, ClearingDeposit, Customer, InvoicePayment, JournalEntryLine, PaymentMethod,
                    SafeBox, Voucher, db)
from routes.clearing import _create_clearing_settlement_voucher
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, vat_mapped):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


@pytest.fixture
def tamara(world):
    clearing_acc = Account(account_number=f'81{uuid.uuid4().int % 10**6:06d}', name=f'تمارا {_uid()}', type='Asset')
    bank_acc = Account(account_number=f'82{uuid.uuid4().int % 10**6:06d}', name=f'بنك {_uid()}', type='Asset')
    fee_acc = Account(account_number=f'83{uuid.uuid4().int % 10**6:06d}', name=f'عمولة {_uid()}', type='Expense')
    db.session.add_all([clearing_acc, bank_acc, fee_acc])
    db.session.flush()
    box = SafeBox(name=f'تمارا {_uid()}', safe_type='clearing', account_id=clearing_acc.id, is_active=True)
    bank = SafeBox(name=f'بنك {_uid()}', safe_type='bank', account_id=bank_acc.id, is_active=True)
    db.session.add_all([box, bank])
    db.session.flush()
    pm = PaymentMethod(payment_type='tamara', name=f'تمارا {_uid()}', commission_rate=6.99,
                       commission_fixed_amount=1.5, commission_per_order=True, is_active=True,
                       default_safe_box_id=box.id, settlement_bank_safe_box_id=bank.id,
                       fee_expense_account_id=fee_acc.id, deposit_confirmation_required=True,
                       deposit_difference_allowed=10.0)
    db.session.add(pm)
    db.session.flush()
    return {'world': world, 'pm': pm, 'box': box, 'bank': bank, 'bank_acc': bank_acc, 'fee_acc': fee_acc}


def _settled(headers, t, amount, fee):
    """A sale paid by Tamara and its settlement, by the real paths."""
    body = {'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': t['world']['holder'].id, 'date': datetime.now().isoformat(),
            'total': amount, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': amount,
            'payments': [{'payment_method_id': t['pm'].id, 'amount': amount}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': amount, 'net': amount,
                       'quantity': 1, 'wage': 0, 'selling_price': amount}]}
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    ip = InvoicePayment.query.filter_by(invoice_id=resp.get_json()['id']).one()
    result = _create_clearing_settlement_voucher(
        clearing_safe_box_id=t['box'].id, bank_safe_box_id=t['bank'].id, gross_amount=amount,
        fee_amount=fee, settlement_dt=datetime(2026, 11, 10, 12), created_by='pytest',
        invoice_payment_ids=[ip.id])
    db.session.flush()
    return db.session.get(Voucher, result['voucher']['id'])


def _post(headers, path, body):
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=headers, json=body)


def _cash(account_id):
    db.session.expire_all()
    dr, cr = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0),
                               func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0))
              .filter(JournalEntryLine.account_id == account_id,
                      JournalEntryLine.is_deleted.is_(False)).one())
    return round(float(dr) - float(cr), 2)


def test_a_shortfall_is_booked_as_commission_and_its_vat_and_the_bank_says_what_came(auth_headers, tamara):
    """1,000 at 6.99 % and 1.50: the settlement booked 917.89; the bank got 912.89."""
    v = _settled(auth_headers, tamara, 1000.0, 71.40)
    bank_before, fee_before = _cash(tamara['bank_acc'].id), _cash(tamara['fee_acc'].id)

    preview = _post(auth_headers, '/api/clearing/deposits/preview',
                    {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 912.89})
    assert preview.status_code == 200, preview.get_data(as_text=True)[:300]
    p = preview.get_json()
    assert (p['expected_net'], p['difference']) == (917.89, 5.0)
    assert (p['fee_difference'], p['vat_difference']) == (4.35, 0.65)
    assert p['note_required'] is False

    resp = _post(auth_headers, '/api/clearing/deposits',
                 {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 912.89,
                  'deposit_date': '2026-11-10', 'bank_reference': 'SABB000630741217'})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    deposit = db.session.get(ClearingDeposit, resp.get_json()['deposit']['id'])
    assert deposit.voucher_id, 'the difference is posted by its own voucher'
    assert _cash(tamara['bank_acc'].id) == pytest.approx(bank_before - 5.0)
    assert _cash(tamara['fee_acc'].id) == pytest.approx(fee_before + 4.35)
    dv = db.session.get(Voucher, deposit.voucher_id)
    assert dv.date.date() == date(2026, 11, 10) and dv.reference_type == 'clearing_deposit'


def test_an_excess_lessens_the_commission(auth_headers, tamara):
    """1,650 on 4 installments charged 5.99 %: the bank got more than booked."""
    v = _settled(auth_headers, tamara, 1650.0, 116.84)   # 6.99 % and 1.50
    fee_before = _cash(tamara['fee_acc'].id)
    resp = _post(auth_headers, '/api/clearing/deposits',
                 {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id],
                  'amount_received': 1534.61, 'deposit_date': '2026-11-10',
                  'note': 'خصمت تمارا 5.99%'})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['deposit']['difference'] == -18.98
    assert _cash(tamara['fee_acc'].id) == pytest.approx(fee_before - 16.50), 'the commission less by the excess'


def test_a_settlement_is_confirmed_once(auth_headers, tamara):
    v = _settled(auth_headers, tamara, 1000.0, 71.40)
    body = {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 917.89,
            'deposit_date': '2026-11-10'}
    first = _post(auth_headers, '/api/clearing/deposits', body)
    assert first.status_code == 201
    assert first.get_json()['deposit']['voucher_id'] is None, 'no difference, nothing posted'
    again = _post(auth_headers, '/api/clearing/deposits', body)
    assert again.status_code == 400 and again.get_json()['error'] == 'settlement_already_confirmed'


def test_a_large_difference_needs_its_reason(auth_headers, tamara):
    v = _settled(auth_headers, tamara, 1000.0, 71.40)
    body = {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 800.0,
            'deposit_date': '2026-11-10'}
    refused = _post(auth_headers, '/api/clearing/deposits', body)
    assert refused.status_code == 400 and refused.get_json()['error'] == 'note_required'
    assert ClearingDeposit.query.filter_by(payment_method_id=tamara['pm'].id).count() == 0
    allowed = _post(auth_headers, '/api/clearing/deposits', {**body, 'note': 'مرتجع خصمته تمارا'})
    assert allowed.status_code == 201, allowed.get_data(as_text=True)[:300]


def test_another_methods_settlement_is_refused(auth_headers, tamara):
    v = _settled(auth_headers, tamara, 1000.0, 71.40)
    other = PaymentMethod(payment_type='tabby', name=f'تابي {_uid()}', is_active=True)
    db.session.add(other)
    db.session.flush()
    resp = _post(auth_headers, '/api/clearing/deposits/preview',
                 {'payment_method_id': other.id, 'voucher_ids': [v.id], 'amount_received': 917.89})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'not_this_methods_settlement'


def test_a_confirmed_settlement_is_not_cancelled_under_its_deposit(auth_headers, tamara):
    v = _settled(auth_headers, tamara, 1000.0, 71.40)
    _post(auth_headers, '/api/clearing/deposits',
          {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 917.89,
           'deposit_date': '2026-11-10'})
    resp = _post(auth_headers, f'/api/vouchers/{v.id}/cancel', {'reason': 'pytest'})
    assert resp.status_code == 409 and resp.get_json()['error'] == 'settlement_deposit_confirmed'


def test_the_differences_voucher_cancelled_unconfirms_its_settlements(auth_headers, tamara):
    v = _settled(auth_headers, tamara, 1000.0, 71.40)
    resp = _post(auth_headers, '/api/clearing/deposits',
                 {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 912.89,
                  'deposit_date': '2026-11-10'})
    deposit_voucher = resp.get_json()['deposit']['voucher_id']
    cancel = _post(auth_headers, f'/api/vouchers/{deposit_voucher}/cancel', {'reason': 'pytest'})
    assert cancel.status_code == 200, cancel.get_data(as_text=True)[:300]
    g.pop('current_user', None)
    listed = flask_app.test_client().get(
        f'/api/clearing/deposits/unconfirmed?payment_method_id={tamara["pm"].id}', headers=auth_headers)
    assert [s['voucher_id'] for s in listed.get_json()['settlements']] == [v.id]


def test_the_night_says_a_settlement_whose_deposit_is_not_confirmed(auth_headers, tamara):
    from services.books_invariants import UNCONFIRMED_DEPOSIT, check_unconfirmed_deposits
    v = _settled(auth_headers, tamara, 1000.0, 71.40)          # its deposit day: 10 Nov

    def said(on):
        return [f for f in check_unconfirmed_deposits(now=on) if f.subject_key == f'voucher:{v.id}']

    assert said(datetime(2026, 11, 12)) == [], 'within its grace'
    (fact,) = said(datetime(2026, 11, 20))
    assert fact.kind == UNCONFIRMED_DEPOSIT and fact.metric == 917.89
    _post(auth_headers, '/api/clearing/deposits',
          {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 917.89,
           'deposit_date': '2026-11-10'})
    assert said(datetime(2026, 11, 20)) == [], 'confirmed, said no more'


def test_the_manual_settlement_is_charged_by_the_one_computation(auth_headers, tamara):
    """The owner, 24 Nov 2026: the plans were set and the settlement screen
    still showed the old rate. The server charges each payment at its kept rate
    and the fee a deposit once; the screen sends it, and the voucher posts it."""
    from models import PaymentMethodPlan
    t = tamara
    t['pm'].plans = [PaymentMethodPlan(installments=4, commission_rate=6.99),
                     PaymentMethodPlan(installments=6, commission_rate=5.99)]
    t['pm'].deposit_fixed_fee = 6.0
    db.session.flush()
    ids = []
    for amount, plan in ((1000.0, 6), (2150.0, 4)):
        body = {'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
                'employee_id': t['world']['holder'].id, 'date': datetime.now().isoformat(),
                'total': amount, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': amount,
                'payments': [{'payment_method_id': t['pm'].id, 'amount': amount, 'installments': plan}],
                'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': amount, 'net': amount,
                           'quantity': 1, 'wage': 0, 'selling_price': amount}]}
        resp = _post(auth_headers, '/api/invoices', body)
        assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
        ids.append(InvoicePayment.query.filter_by(invoice_id=resp.get_json()['id']).one().id)
    charge = _post(auth_headers, '/api/clearing/settlements/charge',
                   {'clearing_safe_box_id': t['box'].id, 'invoice_payment_ids': ids})
    assert charge.status_code == 200, charge.get_data(as_text=True)[:300]
    c = charge.get_json()
    # 1,000 at 5.99 % + 1.50 = 61.40; 2,150 at 6.99 % + 1.50 = 151.79; the deposit's 6.00
    assert (c['fee'], c['payments'], c['has_plans']) == (219.19, 2, True)
    assert c['vat'] == pytest.approx(9.21 + 22.77 + 0.90)
    settled = _create_clearing_settlement_voucher(
        clearing_safe_box_id=t['box'].id, bank_safe_box_id=t['bank'].id, gross_amount=c['gross'],
        fee_amount=c['fee'], fee_vat_amount=c['vat'], settlement_dt=datetime.now(), created_by='pytest',
        invoice_payment_ids=ids)
    from models import VoucherAccountLine
    lines = VoucherAccountLine.query.filter_by(voucher_id=settled['voucher']['id'], line_type='debit').all()
    debits = sorted(round(float(ln.amount), 2) for ln in lines)
    assert c['fee'] in debits and c['vat'] in debits and c['net'] in debits, debits
