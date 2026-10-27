"""What a supplier purchase pays with it is held to what it owes and to what we hold (ADR-062).

Measured on 27 Oct 2026 (a probe on the purchase's payment): 50 g handed to a
supplier owed 20 g was taken, and the supplier then owed us 30 g; it was taken
from a gold safe that held none, and the safe went to -30 g; a gold line of
-5 g was answered «saved» and dropped; and a purchase sent as «آجل» with a
payment was saved paid.

The laws (a supplier purchase, 'شراء'):
  1. «آجل» pays nothing with the invoice -- no cash, no gold.
  2. The gold paid with it is no more than the gold it owes the supplier, at
     the main karat (the cash is held so already: PURCHASE-CASH-1).
  3. Gold is paid from one of our stock safes (a safe with a stock location,
     ADR-045) only as far as it holds that karat before the invoice. A party's
     gold safe -- an office's, a supplier's -- is gold owed, in the party's
     balance, and is not held so.
And for every invoice: a gold settlement line of a negative weight, or of a
weight with no karat, is refused -- not dropped.

The purchase preview says what the save takes now (`payable`), and what is
left of the gold at each karat (`remaining.gold_at_karat`), for the screen.

The cash a purchase can be paid is every cash debt it posts on the supplier
(the owner, 27 Oct 2026: «نعم»): its wages and VAT, its priced stones and
their VAT -- kept on the invoice, frozen (invoice.stones_subtotal,
invoice.stones_tax_total) -- and a karat-difference fee less its commission.

Run:
    python -m pytest tests/test_supplier_purchase_payment_laws.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox, db
from tests.test_supplier_purchase_effect import SHAPES, _balance, world  # noqa: F401 -- the fixture
from tests.test_supplier_purchase_stones import _map_role, supplier  # noqa: F401 -- the fixture
from tests.test_supplier_purchase_stones import _purchase as _stones_purchase


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture(autouse=True)
def _vat(vat_mapped):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


def _gold_safe(*, location='scrap', karat=None, holds_21=0.0):
    """A gold safe on its own weight account, holding [holds_21] g of 21 by a
    posted entry."""
    account = Account(account_number=f'7139{uuid.uuid4().int % 10**5:05d}', name=f'ذهب {_uid()}',
                      type='Asset', tracks_weight=True)
    other = Account(account_number=f'7138{uuid.uuid4().int % 10**5:05d}', name=f'مقابل {_uid()}',
                    type='Asset', tracks_weight=True)
    db.session.add_all([account, other])
    db.session.flush()
    safe = SafeBox(name=f'خزينة {_uid()}', safe_type='gold', account_id=account.id, is_active=True,
                   stock_location=location, karat=karat)
    db.session.add(safe)
    if holds_21:
        entry = JournalEntry(entry_number=f'T-{_uid()}', date=datetime(2026, 1, 1), description='رصيد',
                             entry_type='عادي', is_posted=True, is_draft=False)
        db.session.add(entry)
        db.session.flush()
        db.session.add_all([
            JournalEntryLine(journal_entry_id=entry.id, account_id=account.id, debit_21k=holds_21),
            JournalEntryLine(journal_entry_id=entry.id, account_id=other.id, credit_21k=holds_21),
        ])
    db.session.flush()
    return safe


def _purchase(world, **extra):
    """20 g of 21 owed, a wage of 1,000."""
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload.update(extra)
    return payload


def _save(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def _gold(safe, karat, weight):
    return {'safe_box_id': safe.id, 'karat': karat, 'weight': weight}


# ---- 1. «آجل» pays nothing with the invoice ----

def test_credit_with_a_cash_payment_is_refused(auth_headers, world):
    method = PaymentMethod(name=f'نقدًا {_uid()}', payment_type='cash')
    db.session.add(method)
    db.session.flush()
    resp = _save(auth_headers, _purchase(world, settlement_method='credit', amount_paid=1000.0,
                                         payments=[{'payment_method_id': method.id, 'amount': 1000.0}]))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'credit_pays_nothing_now'


def test_credit_with_gold_is_refused(auth_headers, world):
    safe = _gold_safe(holds_21=50.0)
    resp = _save(auth_headers, _purchase(world, settlement_method='credit',
                                         gold_settlements=[_gold(safe, 21, 5.0)]))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'credit_pays_nothing_now'


# ---- 2. no more gold than is owed ----

def test_gold_beyond_what_is_owed_is_refused(auth_headers, world):
    safe = _gold_safe(holds_21=100.0)
    before = _balance(world['supplier'])
    resp = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[_gold(safe, 21, 50.0)]))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'gold_settled_over_owed'
    assert (body['owed_gold_main'], body['paid_gold_main']) == (20.0, 50.0)
    assert _balance(world['supplier']) == before, 'nothing saved'


def test_gold_up_to_what_is_owed_is_taken(auth_headers, world):
    safe = _gold_safe(holds_21=100.0)
    resp = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[_gold(safe, 21, 20.0)]))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


def test_the_owed_gold_is_compared_at_the_main_karat(auth_headers, world):
    """20 g of 21 owed; 17.5 g of 24 is exactly 20 g of 21 -- taken; 18 g is not."""
    safe = _gold_safe()
    entry = JournalEntry(entry_number=f'T-{_uid()}', date=datetime(2026, 1, 1), description='رصيد',
                         entry_type='عادي', is_posted=True, is_draft=False)
    db.session.add(entry)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=entry.id, account_id=safe.account_id, debit_24k=40.0))
    db.session.flush()
    over = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[_gold(safe, 24, 18.0)]))
    assert over.status_code == 400 and over.get_json()['error'] == 'gold_settled_over_owed'
    exact = _save(auth_headers, _purchase(world, settlement_method='barter',
                                          gold_settlements=[_gold(safe, 24, 17.5)]))
    assert exact.status_code == 201, exact.get_data(as_text=True)[:300]


# ---- 3. our stock gives only the gold it holds ----

def test_gold_a_stock_safe_does_not_hold_is_refused(auth_headers, world):
    safe = _gold_safe(holds_21=3.0)
    resp = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[_gold(safe, 21, 5.0)]))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'gold_safe_short'
    assert (body['safe_box_id'], body['karat'], body['weight']) == (safe.id, 21, 5.0)
    # Its balance is not the seller's (ADR-036): the refusal does not say it.
    assert 'held' not in body and '3' not in body['message']


def test_two_lines_on_one_safe_are_held_together(auth_headers, world):
    safe = _gold_safe(holds_21=8.0)
    resp = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[_gold(safe, 21, 5.0), _gold(safe, 21, 5.0)]))
    assert resp.status_code == 400 and resp.get_json()['error'] == 'gold_safe_short'


def test_gold_a_stock_safe_holds_is_taken(auth_headers, world):
    safe = _gold_safe(holds_21=5.0)
    resp = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[_gold(safe, 21, 5.0)]))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


def test_a_partys_gold_safe_is_not_held_to_a_balance(auth_headers, world):
    """An office's or a supplier's gold safe is gold owed (ADR-051 §5): what it
    holds is the party's balance, which may be either side."""
    safe = _gold_safe(location=None)
    resp = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[_gold(safe, 21, 5.0)]))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


# ---- every invoice: a gold line is taken or refused, never dropped ----

@pytest.mark.parametrize('line', [{'karat': 21, 'weight': -5.0}, {'karat': 0, 'weight': 5.0}])
def test_a_gold_line_that_is_no_gold_is_refused(auth_headers, world, line):
    safe = _gold_safe(holds_21=50.0)
    resp = _save(auth_headers, _purchase(world, settlement_method='barter',
                                         gold_settlements=[{'safe_box_id': safe.id, **line}]))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'invalid_gold_settlement_line'


# ---- the preview says what the save takes ----

def _preview(headers, payload):
    resp = flask_app.test_client().post('/api/invoices/purchase-preview', headers=headers, json=payload)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_the_preview_says_what_is_paid_now_and_the_gold_left_at_each_karat(auth_headers, world):
    preview = _preview(auth_headers, _purchase(world))
    assert preview['payable']['cash'] == 1000.0, 'the wage: the cash the save takes'
    at = preview['remaining']['gold_at_karat']
    assert at['21'] == 20.0
    assert at['24'] == 17.5, 'the 20 g of 21 left, at 24 -- the one conversion'


def test_the_preview_says_a_karat_difference_fee(auth_headers, world):
    """A fee paid for settling in another karat is posted on the supplier with
    the invoice (accounting/karat_diff_commission): the preview says it."""
    payload = _purchase(world, karat_diff_pay_total=300.0)
    preview = _preview(auth_headers, payload)
    resp = _save(auth_headers, payload)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert preview['invoice']['cash'] == 1300.0
    assert preview['payable']['cash'] == 1300.0, 'the fee is paid with it'
    assert preview['after']['cash'] == _balance(world['supplier'])[0]


# ---- the cash it can be paid is every cash debt it posts ----

def _cash_method():
    method = PaymentMethod(name=f'نقدًا {_uid()}', payment_type='cash')
    db.session.add(method)
    db.session.flush()
    return method


def _paid_in_full(headers, payload, amount):
    method = _cash_method()
    payload.update(settlement_method='partial', amount_paid=amount,
                   payments=[{'payment_method_id': method.id, 'amount': amount}])
    resp = _save(headers, payload)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    return db.session.get(Invoice, resp.get_json()['id'])


@pytest.mark.parametrize('vat', [False, True])
def test_priced_stones_are_paid_with_the_invoice(auth_headers, supplier, vat):
    from models import Settings
    _map_role()
    settings = Settings.query.first()
    settings.tax_rate, settings.tax_enabled = 0.15, True
    db.session.flush()
    payload = _stones_purchase(supplier, kind='priced', stones=6.7, value=2000.0, vat=vat)
    tax = payload['stones_tax_total']
    payload.update(total=2000.0 + tax, total_tax=tax)
    preview = _preview(headers=auth_headers, payload=dict(payload))
    assert preview['payable']['cash'] == preview['invoice']['cash'] == round(2000.0 + tax, 2)

    invoice = _paid_in_full(auth_headers, payload, round(2000.0 + tax, 2))
    assert (invoice.stones_subtotal, invoice.stones_tax_total) == (2000.0, tax), 'kept, frozen'
    assert invoice.cash_obligation == round(2000.0 + tax, 2)
    assert invoice.status == 'paid'


def test_a_karat_difference_fee_is_paid_with_the_invoice(auth_headers, world):
    invoice = _paid_in_full(auth_headers, _purchase(world, karat_diff_pay_total=300.0), 1300.0)
    assert invoice.cash_obligation == 1300.0
    assert invoice.status == 'paid'


def test_a_karat_difference_commission_lowers_what_is_paid(auth_headers, world):
    invoice = _paid_in_full(auth_headers, _purchase(world, karat_diff_earn_total=200.0), 800.0)
    assert invoice.cash_obligation == 800.0
    assert invoice.status == 'paid'


def test_more_than_the_debts_is_still_refused(auth_headers, world):
    method = _cash_method()
    resp = _save(auth_headers, _purchase(world, karat_diff_pay_total=300.0, settlement_method='partial',
                                         amount_paid=1400.0,
                                         payments=[{'payment_method_id': method.id, 'amount': 1400.0}]))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]


def test_a_commission_beyond_the_debts_leaves_nothing_to_pay(auth_headers, world):
    resp = _save(auth_headers, _purchase(world, karat_diff_earn_total=1500.0))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    assert db.session.get(Invoice, resp.get_json()['id']).cash_obligation == 0.0


def _migration():
    import importlib.util
    import pathlib
    path = (pathlib.Path(__file__).resolve().parent.parent / 'alembic' / 'versions'
            / '20261027_invoice_stones_totals.py')
    spec = importlib.util.spec_from_file_location('invoice_stones_totals', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_migration_keeps_the_stones_of_purchases_saved_before(auth_headers, supplier):
    """A purchase saved before the columns: its priced stones from its lines,
    their VAT from its frozen taxes (total_tax less the gold's and the wages')."""
    from models import InvoiceItem
    _map_role()
    resp = _save(auth_headers, {**_stones_purchase(supplier, kind='priced', stones=6.7, value=2000.0),
                                'total': 2000.0})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    invoice = db.session.get(Invoice, resp.get_json()['id'])
    invoice.stones_subtotal = invoice.stones_tax_total = None   # as before the columns
    invoice.total_tax, invoice.gold_tax_total, invoice.wage_tax_total = 345.0, 0.0, 45.0
    plain = _save(auth_headers, _stones_purchase(supplier))
    assert plain.status_code == 201
    other = db.session.get(Invoice, plain.get_json()['id'])
    other.stones_subtotal = other.stones_tax_total = None
    db.session.flush()
    assert InvoiceItem.query.filter_by(invoice_id=invoice.id, stones_kind='priced').count() == 1

    _migration().keep_stones_totals(db.session.connection())

    db.session.expire_all()
    invoice = db.session.get(Invoice, invoice.id)
    assert (invoice.stones_subtotal, invoice.stones_tax_total) == (2000.0, 300.0)
    other = db.session.get(Invoice, other.id)
    assert (other.stones_subtotal or 0.0, other.stones_tax_total or 0.0) == (0.0, 0.0)
