"""A settled payment is put right through its settlement (the owner, 31 Oct 2026).

On the 31 Oct copy a Mada payment recorded 7,200 (truly 7,100 and 100 cash)
was settled, then its payment voucher cancelled: accepted -- Mada read
-7,200, the cash customer owed 7,200 he had paid, the invoice partly paid, a
settlement line pointing at a cancelled payment. The owner: «إلغاء سند
التسوية أولًا ثم التصحيح، وليس سند الدفعة». So:

  - a payment voucher is not cancelled while its payment is in a settlement;
    the refusal names the settlement voucher to cancel first -- and so does
    the payment-method correction's;
  - a cancelled settlement is settled again: the scheduler's batch reference
    is not held by a cancelled voucher (it skipped the batch for ever).

Run:
    python -m pytest tests/test_a_settled_payment_is_put_right_through_its_settlement.py -v
"""
import pytest
from flask import g

from app import app as flask_app
from models import InvoicePayment, SettlementLine, Voucher, db
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_clearing_settlement_live_balance import (  # noqa: F401 (fixtures)
    _ledger_cash, _sale_paid_by_mada, _settle, mada, rollback_after_each,
)

REF = 'AUTO-PM-T-B-2026-10-31'


def _post(headers, url, body):
    g.pop('current_user', None)
    resp = flask_app.test_client().post(url, headers=headers, json=body)
    return resp.status_code, resp.get_json() or {}


def _settled(auth_headers, mada):  # noqa: F811
    ip = _sale_paid_by_mada(auth_headers, mada, 400.0)
    result = _settle(mada, 400.0, [ip.id], reference_number=REF, ensure_unique_reference=True)
    return ip, db.session.get(Voucher, result['voucher']['id'])


def test_a_settled_payment_s_voucher_waits_for_its_settlement(auth_headers, mada):  # noqa: F811
    ip, settlement = _settled(auth_headers, mada)
    code, body = _post(auth_headers, f'/api/vouchers/{ip.source_voucher_id}/cancel', {'reason': 'خطأ مبلغ'})
    assert code == 409 and body['error'] == 'payment_settled', body
    assert settlement.voucher_number in body['message'] and 'ألغِ سند التسوية أولًا' in body['message']
    assert db.session.get(Voucher, ip.source_voucher_id).status != 'cancelled'
    assert _ledger_cash(mada['account'].id) == 0.0, 'Mada is not driven below nothing'

    code, body = _post(auth_headers, f'/api/invoices/{ip.invoice_id}/payments/{ip.id}/correct-method',
                       {'new_payment_method_id': mada['world']['pm'].id, 'reason': 'خطأ', 'correction_amount': 100.0})
    assert code == 409 and 'ألغِ سند التسوية أولًا' in body['message'], 'one path, one wording'


def test_the_settlement_cancelled_the_payment_corrected_settled_again(auth_headers, mada):  # noqa: F811
    ip, settlement = _settled(auth_headers, mada)
    assert _post(auth_headers, f'/api/vouchers/{settlement.id}/cancel', {'reason': 'تصحيح دفعة فيها'})[0] == 200
    code, body = _post(auth_headers, f'/api/invoices/{ip.invoice_id}/payments/{ip.id}/correct-method',
                       {'new_payment_method_id': mada['world']['pm'].id, 'reason': 'مدى 300 و100 نقدًا',
                        'correction_amount': 100.0})
    assert code == 200, body
    assert db.session.get(InvoicePayment, ip.id).amount == 300.0

    again = _settle(mada, 300.0, [ip.id], reference_number=REF, ensure_unique_reference=True)
    assert not again.get('skipped'), 'the batch is settled again, its cancelled voucher no hold on it'
    assert SettlementLine.query.filter_by(invoice_payment_id=ip.id).count() == 1
    assert _ledger_cash(mada['account'].id) == 0.0
