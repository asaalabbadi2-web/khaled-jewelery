"""A supplier purchase paid its whole cash obligation is not a partial payment (PURCHASE-CASH-1).

Found 6 Oct 2026 while building the purchase screen's readiness (PURCHASE-UX-1):
for invoice_type='شراء' the invoice total carries the gold's cash value, which
is never a cash debt on the supplier -- the supplier is owed the gold, and in
cash only the wages (unless he takes them in gold) and the VAT:

    Invoice.cash_obligation = wage_subtotal + wage_tax_total + gold_tax_total

InvoicePaymentStateService already measures payment against cash_obligation
(Phase 13). add_invoice does not: with partial payments off and auto-post on,
it demands that the payments equal `total`, so paying the supplier exactly
what he is owed in cash is refused («مجموع المبالغ لا يساوي إجمالي الفاتورة»).

Exposure: latent. On the 6 Oct production copy allow_partial_invoice_payments
is on, so add_invoice only checks overpayment, which cash_obligation < total
never trips. Switching the setting off would refuse every cash payment on a
gold purchase. The screen holds the domain rule (cash paid <= cash owed, and
partial only when allowed) -- utils/purchase_readiness.dart.

Fixed 7 Oct 2026: add_invoice compares a supplier purchase's payments with
its cash obligation (models.purchase_cash_obligation, the one formula), and
refuses paying more than it.

Run:
    python -m pytest tests/test_purchase_cash_paid_against_its_obligation.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, PaymentMethod, SafeBox, Settings, Supplier, db


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
def world():
    from party_account_service import ensure_supplier_accounts
    if not Account.query.filter_by(account_number='1400').first():
        # As production: «ضريبة مدفوعة على المشتريات», where a purchase's VAT goes.
        db.session.add(Account(account_number='1400', name='ضريبة مدفوعة على المشتريات',
                               type='Asset'))
        db.session.flush()
    # As production (tests/test_supplier_purchase_gold_follows_its_entry.py): the
    # display stock account keeps its weight on a memo account, the display
    # safe's.
    stock = Account.query.filter_by(account_number='1300').one()
    memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}',
                   name=f'مخزون معروض وزني {_uid()}', type='Asset', tracks_weight=True)
    db.session.add(memo)
    db.session.flush()
    stock.memo_account_id = memo.id
    db.session.add(SafeBox(name=f'المعروض {_uid()}', safe_type='gold',
                           account_id=memo.id, is_active=True))
    box = SafeBox(name=f'خزينة {_uid()}', safe_type='cash',
                  account_id=Account.query.get(15).id, is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(payment_type='cash', name=f'نقداً {_uid()}', commission_rate=0.0,
                       commission_timing='invoice', is_active=True, default_safe_box_id=box.id)
    supplier = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}', default_wage_type='cash')
    db.session.add_all([pm, supplier])
    db.session.flush()
    ensure_supplier_accounts(supplier)
    db.session.flush()
    return {'pm': pm, 'box': box, 'supplier': supplier}


def _settings(*, allow_partial):
    row = Settings.query.first() or Settings()
    row.auto_post_invoices = True
    row.allow_partial_invoice_payments = allow_partial
    db.session.add(row)
    db.session.flush()


def _purchase_paying_its_cash(w):
    """10 g of 21k worth 3,675.00 with VAT on the gold (551.25): the supplier is
    owed the gold, and 551.25 in cash -- all of which is paid. No wages, so the
    world needs no wage-inventory account."""
    gold, vat = 3675.0, 551.25
    return {
        'invoice_type': 'شراء', 'supplier_id': w['supplier'].id, 'gold_type': 'new',
        'date': datetime.now().isoformat(),
        'total': gold + vat, 'total_tax': vat, 'apply_gold_tax': True,
        'gold_subtotal': gold, 'wage_subtotal': 0.0,
        'wage_tax_total': 0.0, 'gold_tax_total': vat,
        'settlement_method': 'partial',
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1}],
        'payments': [{'payment_method_id': w['pm'].id, 'amount': vat,
                      'safe_box_id': w['box'].id}],
        'amount_paid': vat,
        'safe_box_id': w['box'].id,
    }


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def test_with_partial_payments_on_the_whole_cash_obligation_is_taken(auth_headers, world):
    """The world works: the only difference below is the setting."""
    _settings(allow_partial=True)
    resp = _post(auth_headers, _purchase_paying_its_cash(world))
    assert resp.status_code == 201, resp.get_json()


def test_with_partial_payments_off_the_whole_cash_obligation_is_still_taken(auth_headers, world):
    _settings(allow_partial=False)
    resp = _post(auth_headers, _purchase_paying_its_cash(world))
    assert resp.status_code == 201, resp.get_json()


def test_paying_more_than_the_cash_obligation_is_refused(auth_headers, world):
    """551.25 is owed in cash; 600.00 is more, though far under the 4,226.25
    total that carries the gold's value -- the old check let it through."""
    _settings(allow_partial=True)
    payload = _purchase_paying_its_cash(world)
    payload['payments'][0]['amount'] = 600.0
    payload['amount_paid'] = 600.0
    resp = _post(auth_headers, payload)
    assert resp.status_code == 400
    assert 'النقد المستحق للمورد' in resp.get_json()['error']
