"""What the settlement screen shows before saving is what the server will post (ADR-050).

The screen built «ملخص القيد قبل الحفظ» itself: 15% VAT until the settings
came, and the commission's VAT on the receivable account where, with input
VAT not recovered (ADR-043), the server posts it to the non-recoverable one.
POST /clearing/settlements/preview runs the settlement's own function, reads
the voucher's lines and rolls it all back: its lines are the posted lines,
and nothing of it stays.

Run:
    python -m pytest tests/test_settlement_preview_is_what_is_posted.py -v
"""
import uuid
from datetime import date

import pytest
from flask import g

from app import app as flask_app
from models import Account, Voucher, VatPolicyPeriod, VoucherAccountLine, db
from routes.clearing import commission_vat
from services.vat_policy import non_recoverable_account_id
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_clearing_settlement_live_balance import (  # noqa: F401 (fixtures)
    _ledger_cash, _pending, _sale_paid_by_mada, app, mada, rollback_after_each,
)
from tests.test_input_vat_not_recovered import test_vat_on_nothing_that_enters_the_stock_goes_to_non_recoverable


def _post(path, headers, body):
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=headers, json=body)


@pytest.fixture
def commission(mada):
    """A 2.00 commission on its own expense account, its VAT not recovered."""
    test_vat_on_nothing_that_enters_the_stock_goes_to_non_recoverable()  # 540 and the period
    VatPolicyPeriod.query.delete()
    db.session.add(VatPolicyPeriod(effective_from=date(2000, 1, 1), input_vat_recoverable=False,
                                   sales_vat_charged=False, created_by='t'))
    fee = Account(account_number=f'83{uuid.uuid4().int % 10**6:06d}', name='عمولة', type='Expense')
    db.session.add(fee)
    db.session.flush()
    return fee


def _body(mada, fee_account, ip):
    return {'clearing_safe_box_id': mada['box'].id, 'bank_safe_box_id': mada['bank'].id,
            'gross_amount': 250.0, 'fee_amount': 2.0, 'fee_account_id': fee_account.id,
            'invoice_payment_ids': [ip.id]}


def test_the_preview_is_the_voucher_then_posted(auth_headers, mada, commission):
    ip = _sale_paid_by_mada(auth_headers, mada, 250.0)
    body = _body(mada, commission, ip)

    preview = _post('/api/clearing/settlements/preview', auth_headers, body)
    assert preview.status_code == 200, preview.get_data(as_text=True)[:300]
    shown = preview.get_json()
    assert shown['balanced'] is True

    posted = _post('/api/clearing/settlements', auth_headers, body)
    assert posted.status_code == 201, posted.get_data(as_text=True)[:300]
    voucher_id = posted.get_json()['voucher']['id']
    lines = VoucherAccountLine.query.filter_by(voucher_id=voucher_id).order_by(VoucherAccountLine.id).all()

    assert [(l['account_id'], l['side'], l['amount']) for l in shown['lines']] == \
        [(l.account_id, l.line_type, round(l.amount, 2)) for l in lines]
    vat = commission_vat(2.0)
    assert vat > 0
    assert (non_recoverable_account_id(), 'debit', vat) in \
        [(l['account_id'], l['side'], l['amount']) for l in shown['lines']], 'VAT not recovered: an expense'


def test_the_preview_leaves_nothing(auth_headers, mada, commission):
    ip = _sale_paid_by_mada(auth_headers, mada, 250.0)
    vouchers = Voucher.query.count()

    preview = _post('/api/clearing/settlements/preview', auth_headers, _body(mada, commission, ip))

    assert preview.status_code == 200, preview.get_data(as_text=True)[:300]
    assert Voucher.query.count() == vouchers
    assert _ledger_cash(mada['account'].id) == 250.0
    assert [t['invoice_payment_id'] for t in _pending(auth_headers, mada['box'].id)['transactions']] == [ip.id]


def test_the_preview_refuses_as_the_settlement_does(auth_headers, mada, commission):
    ip = _sale_paid_by_mada(auth_headers, mada, 250.0)
    body = {**_body(mada, commission, ip), 'gross_amount': 260.0}

    preview = _post('/api/clearing/settlements/preview', auth_headers, body)

    assert preview.status_code == 400
    assert preview.get_json()['error'] == 'Clearing balance is insufficient for settlement'
