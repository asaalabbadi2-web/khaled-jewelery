"""A clearing settlement reads the ledger, and a settled payment is not offered again.

Two rules of the clearing screen (routes/clearing.py):
  - _create_clearing_settlement_voucher refuses to settle more than the
    clearing account holds, and the amount it holds is the LEDGER's (posted
    journal lines), not the cached Account.balance_cash -- which drifted far
    on production (BALANCE-001: مدى −270,577 cached against 2,200 posted).
  - GET /clearing/settlements/pending-transactions does not offer a payment
    already settled: through its SettlementLines, or -- settled before
    SettlementLine existed -- through a per_tx:ip_<id> settlement voucher.

These sat in backend/ outside testpaths and failed unseen. The first patched
`routes.live_balances_by_account_ids`, which since the routes split is not the
name routes/clearing.py calls; the second inserted an invoice_payment movement
with no payment, which the pending list no longer reads at all (it reads
InvoicePayment since Apr 2026) -- it passed whatever the code did. Here the
world is made by the real paths: a sale paid by Mada through POST
/api/invoices (its payment, its posted entry on the clearing account), and the
settlement through the function the screen and the scheduler call, which posts
its own entry (APPROVED-ENTRY-001).

Run:
    python -m pytest tests/test_clearing_settlement_live_balance.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from allocation_service import AllocationService
from app import app as flask_app
from models import Account, Customer, InvoicePayment, PaymentMethod, SafeBox, db
from routes.clearing import _create_clearing_settlement_voucher
from services.live_balances import live_balances_by_account_ids
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


@pytest.fixture
def mada(world):
    """A Mada method settling into a clearing box, and the bank it settles to."""
    clearing_acc = Account(account_number=f'81{uuid.uuid4().int % 10**6:06d}', name=f'مقاصة {_uid()}', type='Asset')
    bank_acc = Account(account_number=f'82{uuid.uuid4().int % 10**6:06d}', name=f'بنك {_uid()}', type='Asset')
    db.session.add_all([clearing_acc, bank_acc])
    db.session.flush()
    box = SafeBox(name=f'مدى {_uid()}', safe_type='clearing', account_id=clearing_acc.id, is_active=True)
    bank = SafeBox(name=f'بنك {_uid()}', safe_type='bank', account_id=bank_acc.id, is_active=True)
    db.session.add_all([box, bank])
    db.session.flush()
    pm = PaymentMethod(payment_type='mada', name=f'مدى {_uid()}', commission_rate=0.0,
                       commission_timing='settlement', is_active=True, default_safe_box_id=box.id)
    db.session.add(pm)
    db.session.flush()
    return {'world': world, 'pm': pm, 'box': box, 'bank': bank, 'account': clearing_acc}


def _sale_paid_by_mada(headers, mada, amount) -> InvoicePayment:
    """A sale paid in full by Mada, made and posted by the real creation path."""
    body = {'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': mada['world']['holder'].id, 'date': datetime.now().isoformat(),
            'total': amount, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': amount,
            'payments': [{'payment_method_id': mada['pm'].id, 'amount': amount}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': amount, 'net': amount,
                       'quantity': 1, 'wage': 0, 'selling_price': amount}]}
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return InvoicePayment.query.filter_by(invoice_id=resp.get_json()['id']).one()


def _ledger_cash(account_id):
    return live_balances_by_account_ids([account_id])[account_id]['cash']


def _settle(mada, gross, ip_ids, **kwargs):
    return _create_clearing_settlement_voucher(
        clearing_safe_box_id=mada['box'].id, bank_safe_box_id=mada['bank'].id,
        gross_amount=gross, fee_amount=0.0, settlement_dt=datetime.now(),
        created_by='pytest', invoice_payment_ids=ip_ids, **kwargs)


def _pending(headers, box_id):
    g.pop('current_user', None)
    resp = flask_app.test_client().get(
        f'/api/clearing/settlements/pending-transactions?clearing_safe_box_id={box_id}', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


# ── the balance the settlement checks is the ledger's ─────────────────────────

def test_the_settlement_reads_the_ledger_not_the_cached_balance(auth_headers, mada):
    ip = _sale_paid_by_mada(auth_headers, mada, 250.0)
    assert _ledger_cash(mada['account'].id) == 250.0
    mada['account'].balance_cash = 0.0  # the cache, drifted: it would refuse
    db.session.flush()

    result = _settle(mada, 200.0, [ip.id])

    assert result['success'] is True
    assert result['voucher']['status'] == 'approved' and result['voucher']['journal_entry_id']
    assert result['balances']['clearing_account_cash'] == 50.0  # the ledger after: 250 − 200
    assert _ledger_cash(mada['account'].id) == 50.0


def test_the_settlement_refuses_more_than_the_ledger_holds(auth_headers, mada):
    ip = _sale_paid_by_mada(auth_headers, mada, 250.0)
    mada['account'].balance_cash = 1000.0  # the cache, drifted: it would allow
    db.session.flush()

    with pytest.raises(ValueError, match='^insufficient_clearing_balance$'):
        _settle(mada, 260.0, [ip.id])


# ── a settled payment is not offered again ────────────────────────────────────

def test_a_settled_payment_is_not_offered_again(auth_headers, mada):
    settled = _sale_paid_by_mada(auth_headers, mada, 250.0)
    waiting = _sale_paid_by_mada(auth_headers, mada, 100.0)
    _settle(mada, 250.0, [settled.id])

    data = _pending(auth_headers, mada['box'].id)

    assert [(t['invoice_payment_id'], t['amount']) for t in data['transactions']] == [(waiting.id, 100.0)]
    assert data['pending_count'] == 1 and data['due_amount'] == 100.0


def test_a_payment_settled_before_settlement_lines_is_not_offered_again(auth_headers, mada):
    """The legacy per-transaction settlements wrote no SettlementLine: the
    voucher's notes `per_tx:ip_<id>` are their only record. Made here by the
    real path, then its lines removed by their single writer -- the shape those
    settlements have in the books."""
    settled = _sale_paid_by_mada(auth_headers, mada, 250.0)
    waiting = _sale_paid_by_mada(auth_headers, mada, 100.0)
    result = _settle(mada, 250.0, [settled.id], notes=f'per_tx:ip_{settled.id}')
    from models import Voucher
    assert AllocationService().unallocate(Voucher.query.get(result['voucher']['id'])) == 1
    db.session.flush()

    data = _pending(auth_headers, mada['box'].id)

    assert [t['invoice_payment_id'] for t in data['transactions']] == [waiting.id]
