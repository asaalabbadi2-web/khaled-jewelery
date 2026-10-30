"""A bank statement says an invoice's transfer as a transfer (the owner, 31 Oct 2026).

«في كشف حساب البنك إذا كان الدفع للفاتورة تحويل لا يتم توضيح ذلك في الكشف».
Every payment of an invoice shares one entry; the statements said the entry's
description -- the bank's row for sale 1785 named all three vouchers and no
«تحويل» -- and the line itself said «استلام نقد». Now each line is said by its
own payment: its method, its invoice, its voucher -- the old lines too, read
from the «دفعة #n» their wording names.

Run:
    python -m pytest tests/test_a_bank_statement_says_the_transfer.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def transfer():
    bank_account = Account(account_number=f'83{uuid.uuid4().int % 10**6:06d}', name='بنك اختبار', type='Asset')
    db.session.add(bank_account)
    db.session.flush()
    bank = SafeBox(name=f'بنك {uuid.uuid4().hex[:6]}', safe_type='bank', account_id=bank_account.id, is_active=True)
    db.session.add(bank)
    db.session.flush()
    pm = PaymentMethod(payment_type='bank_transfer', name='تحويل', commission_rate=0.0, is_active=True,
                       default_safe_box_id=bank.id)
    db.session.add(pm)
    db.session.flush()
    return {'pm': pm, 'account': bank_account}


def _sale(headers, world, transfer):  # noqa: F811
    body = {'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': world['holder'].id, 'date': datetime.now().isoformat(),
            'total': 1000.0, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': 1000.0,
            'payments': [{'payment_method_id': world['pm'].id, 'amount': 100.0},
                         {'payment_method_id': transfer['pm'].id, 'amount': 900.0}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]}
    from flask import g
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return db.session.get(Invoice, resp.get_json()['id'])


def _rows(headers, account, path='statement'):
    from flask import g
    g.pop('current_user', None)
    data = flask_app.test_client().get(f'/api/accounts/{account.id}/{path}', headers=headers).get_json()
    return [r for r in data['lines'] if r.get('reference_type') == 'invoice_payments']


def _bank_line(transfer):
    return (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntry.reference_type == 'invoice_payments',
                    JournalEntryLine.account_id == transfer['account'].id).one())


def test_the_bank_says_its_transfer_and_only_its_voucher(auth_headers, world, transfer):  # noqa: F811
    sale = _sale(auth_headers, world, transfer)
    line = _bank_line(transfer)
    assert line.description.startswith('استلام تحويل - دفعة #'), 'written by its method, not «نقد»'
    for path in ('statement', 'statement_merged'):
        (row,) = _rows(auth_headers, transfer['account'], path)
        assert row['description'].startswith('تحويل — دفعة فاتورة'), (path, row['description'])
        assert str(sale.invoice_type_id) in row['description'] or (sale.invoice_number or '') in row['description']
        assert row['description'].count('(') == 1, f'its own voucher alone: {row["description"]}'


def test_an_old_line_is_said_by_the_payment_its_wording_names(auth_headers, world, transfer):  # noqa: F811
    _sale(auth_headers, world, transfer)
    line = _bank_line(transfer)
    payment_no = line.description.split('#')[1].split(' ')[0]
    line.source_voucher_id = None                                    # as the lines before the tag
    line.description = f'استلام نقد - دفعة #{payment_no} (RV-2026-00001)'
    db.session.flush()
    (row,) = _rows(auth_headers, transfer['account'])
    assert row['description'].startswith('تحويل — دفعة فاتورة') and row['description'].endswith('(RV-2026-00001)')
