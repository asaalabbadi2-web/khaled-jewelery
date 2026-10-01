"""A gold difference within a fixed margin counts as paid -- set in the settings (the owner, 2 Oct 2026).

Converting between karats rounds: 24.2 g of 18k is 20.7429 g of 21k and is
attributed as 20.74; weights from the scale differ by hundredths. With only
0.005 g of slack an invoice could stay «partially paid» over a thousandth of a
gram. The owner: a fixed margin in grams of the main karat, set in the system
settings -- 0.05 g to begin with; a percent is impractical. Both ways: a
payment a little short settles the invoice, and a little over can be
attributed. It changes the invoice's status only --
the entries, and the supplier's gold balance, keep every gram.

Run:
    python -m pytest tests/test_gold_settlement_tolerance.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    Account, GoldAttributionBoundary, Invoice, InvoiceGoldObligation, Settings, Supplier, Voucher,
    VoucherAccountLine, db,
)
from party_account_service import ensure_supplier_accounts
from services.gold_allocation_service import attribute_gold_to_invoice


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    if GoldAttributionBoundary.query.first() is None:
        db.session.add(GoldAttributionBoundary(max_historical_voucher_id=0))
        db.session.flush()
    yield


def _uid():
    return uuid.uuid4().hex[:8]


def _tolerance(grams):
    row = Settings.query.first() or Settings()
    row.gold_settlement_tolerance_grams = grams
    db.session.add(row)
    db.session.flush()


def _purchase_owing(karat=18.0, weight=24.2):
    """3133's shape: a purchase owing its gold, no cash left to pay."""
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء', supplier_id=s.id,
                  date=datetime.now(), total=0.0, wage_subtotal=0.0, status='unpaid', amount_paid=0.0,
                  is_posted=True, gold_settlement_tracked=True)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceGoldObligation(invoice_id=inv.id, karat=karat, weight=weight))
    db.session.flush()
    return s, inv


def _gold_voucher(supplier_id, karat, weight):
    v = Voucher(voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
                party_type='supplier', supplier_id=supplier_id, status='approved', created_by='t')
    db.session.add(v)
    db.session.flush()
    acc = Account(account_number=f'9{_uid()[:5]}', name='حساب', type='Liability')
    db.session.add(acc)
    db.session.flush()
    db.session.add(VoucherAccountLine(voucher_id=v.id, account_id=acc.id, line_type='debit',
                                      amount_type='gold', amount=weight, karat=karat))
    db.session.flush()
    return v


def _pay(weight, karat=18.0, owed=24.2):
    s, inv = _purchase_owing(karat, owed)
    v = _gold_voucher(s.id, karat, max(weight, owed))
    attribute_gold_to_invoice(voucher=v, invoice_id=inv.id, karat=karat, weight=weight)
    db.session.flush()
    db.session.expire_all()
    return db.session.get(Invoice, inv.id).status


def test_a_remainder_within_the_tolerance_counts_as_paid():
    _tolerance(0.05)
    assert _pay(24.15) == 'paid'                   # 0.043 g of 21k short


def test_a_remainder_beyond_it_does_not():
    _tolerance(0.05)
    assert _pay(24.10) == 'partially_paid'         # 0.086 g short


def test_with_no_tolerance_set_only_the_rounding_slack_remains():
    _tolerance(0.0)
    assert _pay(24.15) == 'partially_paid'
    assert _pay(24.2) == 'paid'                    # 20.74 against 20.7429: rounding


def test_a_little_over_the_obligation_can_be_attributed_and_pays_it():
    _tolerance(0.05)
    assert _pay(24.25) == 'paid'                   # 0.043 g over
    with pytest.raises(ValueError, match='exceeds_invoice_obligation'):
        _pay(24.30)                                # 0.086 g over


def test_the_settings_carry_it_and_refuse_a_negative(auth_headers):
    c = flask_app.test_client()
    resp = c.put('/api/settings', headers=auth_headers, json={'gold_settlement_tolerance_grams': 0.1})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert c.get('/api/settings', headers=auth_headers).get_json()['gold_settlement_tolerance_grams'] == 0.1
    assert c.put('/api/settings', headers=auth_headers,
                 json={'gold_settlement_tolerance_pct': 0.2}).status_code == 400   # no percent
    assert c.put('/api/settings', headers=auth_headers,
                 json={'gold_settlement_tolerance_grams': -1}).status_code == 400
