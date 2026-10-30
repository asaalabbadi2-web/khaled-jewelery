"""An invoice says which of its payments were cancelled (the owner, 31 Oct 2026).

«هل إلغاء سند دفعة يحدّث الدفعات في عرض الفاتورة؟» -- the paid amount did, the
list did not: sale 1785's three cancelled payments were listed as standing and
totalled 11,100 beside «المدفوع 0». Each payment now says its voucher and
whether it was cancelled, by the payment state's own rule; the totals are the
standing payments'.

Run:
    python -m pytest tests/test_an_invoice_says_its_cancelled_payments.py -v
"""
import pytest
from flask import g

from app import app as flask_app
from models import Invoice, Voucher, db
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_clearing_settlement_live_balance import mada, rollback_after_each, _sale_paid_by_mada  # noqa: F401


def _invoice(headers, invoice_id):
    g.pop('current_user', None)
    data = flask_app.test_client().get(f'/api/invoices/{invoice_id}', headers=headers).get_json()
    return data.get('invoice', data)


def test_a_cancelled_payment_is_said_cancelled_and_left_out_of_the_totals(auth_headers, mada):  # noqa: F811
    ip = _sale_paid_by_mada(auth_headers, mada, 400.0)
    voucher = db.session.get(Voucher, ip.source_voucher_id)
    before = _invoice(auth_headers, ip.invoice_id)
    (row,) = before['payments']
    assert (row['cancelled'], row['voucher_number']) == (False, voucher.voucher_number)
    assert before['total_payments_amount'] == 400.0

    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api/vouchers/{voucher.id}/cancel', headers=auth_headers,
                                        json={'reason': 'خطأ'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    after = _invoice(auth_headers, ip.invoice_id)
    (row,) = after['payments']
    assert row['cancelled'] is True, 'its history stays, said cancelled'
    assert after['total_payments_amount'] == 0.0
    assert float(after.get('amount_paid') or 0.0) == after['total_payments_amount'], 'the list agrees with the paid'
