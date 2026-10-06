"""A supplier purchase carries its VAT decision, and the server holds it (PURCHASE-VAT-1).

Purchases with and without VAT are intentional (the owner, 6 Oct 2026): on
the 6 Oct production copy 26 purchases carry VAT, exactly 15 % of wages, and
132 carry none -- individuals never charge it, companies usually do. Until
now the decision was a switch kept on the device; the invoice kept only a
zero tax, and a no-VAT purchase entered as manual weight lines was refused
(tax_policy_mismatch), the server holding every karat line to the policy.

The law: a supplier purchase may say vat_applied (true / false). It is
recorded on the invoice. Under false no VAT is taken -- a karat line's VAT is
expected to be zero, and a payload that says false but carries VAT is
refused. Without the key, the invoice behaves as before and records nothing.

Run:
    python -m pytest tests/test_purchase_vat_decision.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, SafeBox, Settings, Supplier, db


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
    """As production: wage inventory 1320, VAT on purchases 1400, the display
    stock's weight on a memo account; VAT on at 15 %, capitalized wages."""
    from party_account_service import ensure_supplier_accounts
    for number, name in (('1320', 'مخزون أجور المصنعية'), ('1400', 'ضريبة مدفوعة على المشتريات')):
        if not Account.query.filter_by(account_number=number).first():
            db.session.add(Account(account_number=number, name=name, type='Asset'))
    stock = Account.query.filter_by(account_number='1300').one()
    memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}',
                   name=f'مخزون معروض وزني {_uid()}', type='Asset', tracks_weight=True)
    db.session.add(memo)
    db.session.flush()
    stock.memo_account_id = memo.id
    db.session.add(SafeBox(name=f'المعروض {_uid()}', safe_type='gold', account_id=memo.id, is_active=True))
    supplier = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}', default_wage_type='cash')
    db.session.add(supplier)
    row = Settings.query.first() or Settings()
    row.tax_enabled = True
    row.tax_rate = 0.15
    row.auto_post_invoices = True
    row.manufacturing_wage_mode = 'inventory'
    db.session.add(row)
    db.session.flush()
    ensure_supplier_accounts(supplier)
    db.session.flush()
    from accounting.mappings import _ACCOUNT_NUMBER_CACHE
    for n in ('1320', '1400'):
        _ACCOUNT_NUMBER_CACHE.pop(n, None)
    return {'supplier': supplier}


def _manual_lines_purchase(w, *, wage_tax, **extra):
    """10 g of 21k entered as a manual weight line: gold 3,675.00, wages 200.00."""
    gold, wage = 3675.0, 200.0
    return {
        'invoice_type': 'شراء', 'supplier_id': w['supplier'].id, 'gold_type': 'new',
        'date': datetime.now().isoformat(),
        'total': gold + wage + wage_tax, 'total_tax': wage_tax,
        'gold_subtotal': gold, 'wage_subtotal': wage,
        'wage_tax_total': wage_tax, 'gold_tax_total': 0.0,
        'settlement_method': 'credit', 'amount_paid': 0.0, 'items': [],
        'karat_lines': [{'karat': 21, 'weight_grams': 10.0, 'gold_value_cash': gold,
                         'manufacturing_wage_cash': wage, 'gold_tax': 0.0, 'wage_tax': wage_tax}],
        **extra,
    }


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def test_a_no_vat_purchase_on_manual_lines_is_taken_and_recorded(auth_headers, world):
    resp = _post(auth_headers, _manual_lines_purchase(world, wage_tax=0.0, vat_applied=False))
    assert resp.status_code == 201, resp.get_json()
    inv = db.session.get(Invoice, resp.get_json()['id'])
    assert inv.vat_applied is False
    assert (inv.total_tax or 0) == 0


def test_a_vat_purchase_records_its_decision(auth_headers, world):
    resp = _post(auth_headers, _manual_lines_purchase(world, wage_tax=30.0, vat_applied=True))
    assert resp.status_code == 201, resp.get_json()
    inv = db.session.get(Invoice, resp.get_json()['id'])
    assert inv.vat_applied is True
    assert round(inv.wage_tax_total, 2) == 30.0


def test_a_purchase_that_says_no_vat_and_carries_vat_is_refused(auth_headers, world):
    resp = _post(auth_headers, _manual_lines_purchase(world, wage_tax=30.0, vat_applied=False))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'vat_decision_mismatch'


def test_a_vat_decision_is_true_or_false(auth_headers, world):
    resp = _post(auth_headers, _manual_lines_purchase(world, wage_tax=30.0, vat_applied='yes'))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invalid_vat_applied'


def test_without_a_decision_an_untaxed_manual_line_is_refused(auth_headers, world):
    """No key: the policy holds. A sent 0 is a figure (0 == False in Python had
    made the server read it as absent and tax the line to policy, silently)."""
    refused = _post(auth_headers, _manual_lines_purchase(world, wage_tax=0.0))
    assert refused.status_code == 400
    assert refused.get_json()['error'] == 'tax_policy_mismatch'


def test_without_a_decision_nothing_is_recorded(auth_headers, world):
    # One request per test: a refusal rolls the session back, fixture included.
    taken = _post(auth_headers, _manual_lines_purchase(world, wage_tax=30.0))
    assert taken.status_code == 201, taken.get_json()
    assert db.session.get(Invoice, taken.get_json()['id']).vat_applied is None
