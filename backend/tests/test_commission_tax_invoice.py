"""A commission's VAT waits for its tax invoice (ADR-101).

An installment company issues one tax invoice a month for the commissions of
that month's orders (Tamara's October: 2,694.62 + 404.19 VAT, invoice
92819528 of 1 Nov 2026); the settlement books the commission's VAT the day the
deposit is due. Claimed at the deposit, the return held 432.25 of October's
898.26 and a late-September order's VAT twice (the owner, 25 Nov 2026: Q3
filed September's invoices). For a method set to issue a monthly tax invoice,
the commission's VAT -- a settlement's and a deposit's difference -- waits on
the method's own pending account, outside the return; the invoice, entered,
moves its VAT to input VAT on its date, and what the pending account holds
beyond the months still waiting -- the rounding -- goes to the commission. The
bank is never touched.

Run:
    python -m pytest tests/test_commission_tax_invoice.py -v
"""
import uuid
from datetime import date, datetime

import pytest
from flask import g
from sqlalchemy import func

from app import app as flask_app
from models import (Account, AccountingMapping, Customer, InvoicePayment, JournalEntryLine, PaymentMethod,
                    SafeBox, Voucher, db)
from routes.clearing import _create_clearing_settlement_voucher
from tests.retraction_world import world  # noqa: F401 (fixture)

TAX_NUMBER = '310534637100003'


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, vat_mapped):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


@pytest.fixture
def claim():
    """The commission's input VAT under its group, as 1410 under 140 on production."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    parent = Account(account_number=f'9{uuid.uuid4().int % 10**3:03d}', name=f'ضريبة مدينة {_uid()}', type='Asset')
    db.session.add(parent)
    db.session.flush()
    account = Account(account_number=f'{parent.account_number}1', name='ضريبة عمولات نقاط البيع', type='Asset',
                      parent_id=parent.id)
    db.session.add(account)
    db.session.flush()
    AccountingMapping.query.filter_by(account_type='commission_vat').update({'is_active': False})
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='commission_vat',
                                     account_id=account.id, is_active=True))
    db.session.flush()
    return account


@pytest.fixture
def tamara(world, claim):
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
                       deposit_difference_allowed=10.0, tax_invoice_from=date(2026, 9, 1),
                       applicable_invoice_types=['بيع', 'مرتجع بيع'])
    db.session.add(pm)
    db.session.flush()
    return {'world': world, 'pm': pm, 'box': box, 'bank': bank, 'bank_acc': bank_acc, 'fee_acc': fee_acc,
            'claim': claim}


def _settled(headers, t, amount, fee, sold, settled):
    """A sale paid by the method on *sold*, and its settlement on *settled*, by the real paths."""
    body = {'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': t['world']['holder'].id, 'date': sold.isoformat(),
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
        fee_amount=fee, settlement_dt=settled, created_by='pytest', invoice_payment_ids=[ip.id])
    db.session.flush()
    return db.session.get(Voucher, result['voucher']['id'])


def _post(headers, path, body):
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=headers, json=body)


def _cash(account_id):
    if account_id is None:
        return 0.0
    db.session.expire_all()
    dr, cr = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0),
                               func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0))
              .filter(JournalEntryLine.account_id == account_id,
                      JournalEntryLine.is_deleted.is_(False)).one())
    return round(float(dr) - float(cr), 2)


def _pending(t):
    db.session.expire_all()
    return db.session.get(PaymentMethod, t['pm'].id).commission_vat_pending_account_id


def _invoice(t, month, vat, fee=None, **kw):
    body = {'payment_method_id': t['pm'].id, 'month': month, 'invoice_number': kw.pop('number', f'N{_uid()}'),
            'invoice_date': kw.pop('invoice_date', None) or f'{month}-28',
            'fee_amount': fee if fee is not None else round(vat / 0.15, 2), 'vat_amount': vat,
            'supplier_tax_number': kw.pop('tax_number', TAX_NUMBER)}
    body.update(kw)
    return body


def test_a_settlement_waiting_for_its_invoice_keeps_its_vat_off_the_return(auth_headers, tamara):
    """1,000 at 6.99 % and 1.50: 71.40 and 10.71 VAT -- on the pending account, not input VAT."""
    claim_before = _cash(tamara['claim'].id)
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 10, 5, 10), datetime(2026, 10, 10, 12))
    assert _cash(tamara['claim'].id) == claim_before, 'no VAT claimed before its tax invoice'
    pending = _pending(tamara)
    assert pending is not None, 'the method has its pending account'
    assert _cash(pending) == pytest.approx(10.71)
    account = db.session.get(Account, pending)
    assert account.parent_id == tamara['claim'].parent_id, 'beside the input VAT it waits to become'


def test_a_method_without_a_monthly_invoice_claims_as_before(auth_headers, tamara):
    tamara['pm'].tax_invoice_from = None
    db.session.flush()
    before = _cash(tamara['claim'].id)
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 10, 5, 10), datetime(2026, 10, 10, 12))
    assert _cash(tamara['claim'].id) == pytest.approx(before + 10.71)
    assert _pending(tamara) is None


def test_the_invoice_claims_its_vat_and_the_rounding_goes_to_the_commission(auth_headers, tamara):
    """Two October orders, 10.71 + 17.53 = 28.24 pending; October's invoice says 28.27."""
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 10, 5, 10), datetime(2026, 10, 10, 12))
    _settled(auth_headers, tamara, 1650.0, 116.84, datetime(2026, 10, 6, 10), datetime(2026, 10, 10, 13))
    pending = _pending(tamara)
    assert _cash(pending) == pytest.approx(28.24)
    bank, claim, fee = (_cash(tamara['bank_acc'].id), _cash(tamara['claim'].id), _cash(tamara['fee_acc'].id))

    resp = _post(auth_headers, '/api/clearing/tax-invoices', _invoice(tamara, '2026-10', 28.27, fee=188.24,
                                                                      invoice_date='2026-11-01'))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    inv = resp.get_json()['invoice']
    assert inv['rounding_moved'] == pytest.approx(-0.03)
    assert _cash(tamara['claim'].id) == pytest.approx(claim + 28.27), 'the invoice VAT is claimed, whole'
    assert _cash(pending) == pytest.approx(0.0)
    assert _cash(tamara['fee_acc'].id) == pytest.approx(fee - 0.03), 'the rounding: the commission'
    assert _cash(tamara['bank_acc'].id) == bank, 'the bank is never touched'
    v = db.session.get(Voucher, inv['voucher_id'])
    assert v.date.date() == date(2026, 11, 1) and v.reference_type == 'commission_invoice'


def test_a_later_months_vat_stays_pending(auth_headers, tamara):
    """September's invoice entered after October's order was settled: October's VAT still waits."""
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 9, 20, 10), datetime(2026, 9, 28, 12))
    _settled(auth_headers, tamara, 1650.0, 116.84, datetime(2026, 10, 6, 10), datetime(2026, 10, 10, 13))
    resp = _post(auth_headers, '/api/clearing/tax-invoices', _invoice(tamara, '2026-09', 10.71, fee=71.40,
                                                                      invoice_date='2026-10-01'))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['invoice']['rounding_moved'] == pytest.approx(0.0)
    assert _cash(_pending(tamara)) == pytest.approx(17.53), "October's VAT waits for October's invoice"


def test_a_deposits_vat_difference_waits_too(auth_headers, tamara):
    v = _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 10, 5, 10), datetime(2026, 10, 10, 12))
    claim = _cash(tamara['claim'].id)
    resp = _post(auth_headers, '/api/clearing/deposits',
                 {'payment_method_id': tamara['pm'].id, 'voucher_ids': [v.id], 'amount_received': 912.89,
                  'deposit_date': '2026-10-10'})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert _cash(tamara['claim'].id) == claim
    assert _cash(_pending(tamara)) == pytest.approx(10.71 + 0.65)


@pytest.mark.parametrize('change, code', [
    ({'month': '2026-08'}, 'month_before_invoices'),
    ({'tax_number': '123'}, 'invalid_tax_number'),
    ({'vat_amount': 30.00}, 'vat_not_its_rate'),
    ({'invoice_date': '2026-10-30'}, 'invoice_before_its_month_ends'),
    ({'invoice_number': ''}, 'invoice_number_required'),
])
def test_an_invoice_is_refused_and_writes_nothing(auth_headers, tamara, change, code):
    change = dict(change)          # the parameter is pytest's, shared by every run of this case
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 10, 5, 10), datetime(2026, 10, 10, 12))
    body = _invoice(tamara, change.pop('month', '2026-10'), 10.71, fee=71.40, invoice_date='2026-11-01')
    if 'tax_number' in change:
        body['supplier_tax_number'] = change.pop('tax_number')
    body.update(change)
    before = Voucher.query.count()
    resp = _post(auth_headers, '/api/clearing/tax-invoices', body)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == code
    assert Voucher.query.count() == before


def test_a_month_has_one_invoice_and_a_method_without_them_none(auth_headers, tamara):
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 10, 5, 10), datetime(2026, 10, 10, 12))
    body = _invoice(tamara, '2026-10', 10.71, fee=71.40, invoice_date='2026-11-01')
    assert _post(auth_headers, '/api/clearing/tax-invoices', body).status_code == 201
    again = _post(auth_headers, '/api/clearing/tax-invoices', {**body, 'invoice_number': 'other'})
    assert again.status_code == 400 and again.get_json()['error'] == 'month_already_invoiced'

    tamara['pm'].tax_invoice_from = None
    db.session.flush()
    none = _post(auth_headers, '/api/clearing/tax-invoices', _invoice(tamara, '2026-09', 1.0, fee=6.67))
    assert none.status_code == 400 and none.get_json()['error'] == 'method_has_no_tax_invoices'


def test_cancelling_the_invoice_puts_its_vat_back_to_wait(auth_headers, tamara):
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 10, 5, 10), datetime(2026, 10, 10, 12))
    claim = _cash(tamara['claim'].id)
    resp = _post(auth_headers, '/api/clearing/tax-invoices',
                 _invoice(tamara, '2026-10', 10.71, fee=71.40, invoice_date='2026-11-01'))
    voucher_id = resp.get_json()['invoice']['voucher_id']
    cancel = _post(auth_headers, f'/api/vouchers/{voucher_id}/cancel', {'reason': 'رقم خاطئ'})
    assert cancel.status_code == 200, cancel.get_data(as_text=True)[:300]
    assert _cash(tamara['claim'].id) == pytest.approx(claim)
    assert _cash(_pending(tamara)) == pytest.approx(10.71)
    listed = flask_app.test_client().get(f'/api/clearing/tax-invoices?payment_method_id={tamara["pm"].id}',
                                         headers=auth_headers)
    november = [m for m in listed.get_json()['months'] if m['month'] == '2026-10'][0]
    assert november['invoice'] is None, 'the month waits for its invoice again'


def test_the_months_say_what_each_waits_for(auth_headers, tamara):
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 9, 20, 10), datetime(2026, 9, 28, 12))
    g.pop('current_user', None)
    resp = flask_app.test_client().get(f'/api/clearing/tax-invoices?payment_method_id={tamara["pm"].id}',
                                       headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    october = [m for m in body['months'] if m['month'] == '2026-09'][0]
    assert october['orders'] == 1
    assert (october['computed_fee'], october['computed_vat']) == (71.40, 10.71)
    assert october['invoice'] is None
    assert body['pending_vat'] == pytest.approx(10.71)


def test_the_nightly_check_reports_a_month_without_its_invoice(auth_headers, tamara):
    from services.books_invariants import MISSING_COMMISSION_TAX_INVOICE, check_missing_commission_tax_invoices
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 9, 20, 10), datetime(2026, 9, 28, 12))
    facts = [f for f in check_missing_commission_tax_invoices(now=datetime(2026, 11, 1, 3))
             if f.subject_key == f'method:{tamara["pm"].id}:2026-09']
    assert len(facts) == 1 and facts[0].kind == MISSING_COMMISSION_TAX_INVOICE
    assert check_missing_commission_tax_invoices(now=datetime(2026, 10, 3, 3)) == [] or all(
        f.subject_key != f'method:{tamara["pm"].id}:2026-09'
        for f in check_missing_commission_tax_invoices(now=datetime(2026, 10, 3, 3))), 'within the grace'


def test_the_method_is_set_to_issue_them_from_the_settings(auth_headers, tamara):
    g.pop('current_user', None)
    resp = flask_app.test_client().put(f'/api/payment-methods/{tamara["pm"].id}', headers=auth_headers,
                                       json={'tax_invoice_from': '2026-11-01'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    assert db.session.get(PaymentMethod, tamara['pm'].id).tax_invoice_from == date(2026, 11, 1)
    assert resp.get_json()['payment_method']['tax_invoice_from'] == '2026-11-01'
    g.pop('current_user', None)
    off = flask_app.test_client().put(f'/api/payment-methods/{tamara["pm"].id}', headers=auth_headers,
                                      json={'tax_invoice_from': None})
    assert off.status_code == 200
    db.session.expire_all()
    assert db.session.get(PaymentMethod, tamara['pm'].id).tax_invoice_from is None


@pytest.fixture
def recovered():
    """«ضريبة مدخلات مستردة من الإقرار» under its role's group, as the 2026 VAT repair made it (ADR-089)."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    from services.repair.commission_vat_wait import RECOVERED_NAME, RECOVERED_PARENT_ROLE
    parent = Account(account_number=f'8{uuid.uuid4().int % 10**3:03d}', name=f'إدارية {_uid()}', type='Expense')
    db.session.add(parent)
    db.session.flush()
    account = Account(account_number=f'{parent.account_number}5', name=RECOVERED_NAME, type='Expense',
                      parent_id=parent.id)
    db.session.add(account)
    mapping = AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                                account_type=RECOVERED_PARENT_ROLE).one_or_none()
    if mapping is None:
        db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                         account_type=RECOVERED_PARENT_ROLE, account_id=parent.id, is_active=True))
    else:
        mapping.account_id, mapping.is_active = parent.id, True
    db.session.flush()
    return account


def test_the_tool_puts_the_vat_claimed_before_its_invoice_to_wait(auth_headers, tamara, recovered):
    """Claimed at the settlement before the method was set: an August order settled in September -- its
    VAT in August's return already -- and a September order. The tool moves the first to «مستردة من
    الإقرار», the second to wait for September's invoice; a second run finds it done."""
    from services.repair.commission_vat_wait import move
    tamara['pm'].tax_invoice_from = None
    db.session.flush()
    claim = _cash(tamara['claim'].id)
    _settled(auth_headers, tamara, 1000.0, 71.40, datetime(2026, 8, 28, 10), datetime(2026, 9, 3, 12))
    _settled(auth_headers, tamara, 1650.0, 116.84, datetime(2026, 9, 6, 10), datetime(2026, 9, 10, 12))
    assert _cash(tamara['claim'].id) == pytest.approx(claim + 28.24), 'claimed at the settlements'
    tamara['pm'].tax_invoice_from = date(2026, 9, 1)
    db.session.flush()

    result = move(tamara['pm'], by='pytest', now=datetime(2026, 11, 25, 10))
    [september] = result['written']
    assert (september['month'], september['to_pending'], september['to_recovered']) == ('2026-09', 17.53, 10.71)
    assert september['date'] == '2026-09-30'
    assert _cash(tamara['claim'].id) == pytest.approx(claim), 'nothing claimed before its invoice'
    assert _cash(_pending(tamara)) == pytest.approx(17.53)
    assert _cash(recovered.id) == pytest.approx(10.71), 'claimed twice: its return had it'

    again = move(tamara['pm'], by='pytest', now=datetime(2026, 11, 25, 11))
    assert again['written'] == [] and [d['month'] for d in again['done']] == ['2026-09']

    resp = _post(auth_headers, '/api/clearing/tax-invoices',
                 _invoice(tamara, '2026-09', 17.53, fee=116.84, invoice_date='2026-10-01'))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['invoice']['rounding_moved'] == 0.0
    assert _cash(tamara['claim'].id) == pytest.approx(claim + 17.53), "September's VAT claimed by its invoice"
