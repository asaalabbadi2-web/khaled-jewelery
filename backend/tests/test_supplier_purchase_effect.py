"""What a supplier purchase adds to the supplier is said in one place, and the save posts it (ADR-060 follow-up, option أ).

services/supplier_purchase_effect.py reads the request once: the cash the
supplier is owed (the gold's VAT, the wage and its VAT, priced stones) and its
gold by karat. The save takes its supplier lines' amounts from it, and the
purchase preview says them -- so what is previewed is what is posted.

The law: for every shape of a purchase request, the save's cash credit on the
supplier's financial account and its gold credits on the supplier's memo
account are exactly what supplier_purchase_owed says (س١); and the purchase
preview, asked before the save, says what the supplier's balance is now and
what it is after -- the server's reader's, before and after the save (س٢).

Run:
    python -m pytest tests/test_supplier_purchase_effect.py -v
"""
import uuid
from datetime import datetime

import pytest
from sqlalchemy import func

from app import app as flask_app
from models import Account, Invoice, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox, Settings, Supplier, db
from services.supplier_purchase_effect import supplier_purchase_owed

KARATS = ('18', '21', '22', '24')


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


@pytest.fixture
def world():
    """As production: wage inventory 1320, VAT on purchases 1400, the display
    stock's weight on a memo account; VAT on at 15 %."""
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
    display = SafeBox(name=f'المعروض {_uid()}', safe_type='gold', account_id=memo.id, is_active=True)
    db.session.add(display)
    supplier = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}', default_wage_type='cash')
    db.session.add(supplier)
    row = Settings.query.first() or Settings()
    row.tax_enabled = True
    row.tax_rate = 0.15
    row.auto_post_invoices = True
    row.manufacturing_wage_mode = 'inventory'
    db.session.add(row)
    db.session.flush()
    accounts = ensure_supplier_accounts(supplier)
    db.session.flush()
    from accounting.mappings import _ACCOUNT_NUMBER_CACHE
    for n in ('1320', '1400'):
        _ACCOUNT_NUMBER_CACHE.pop(n, None)
    return {'supplier': supplier, 'accounts': accounts, 'display': display}


def _base(w, **extra):
    return {'invoice_type': 'شراء', 'supplier_id': w['supplier'].id, 'gold_type': 'new',
            'date': datetime.now().isoformat(), 'settlement_method': 'credit',
            'amount_paid': 0.0, **extra}


# Each shape: the request, and the gold the save adds up from its items -- or
# from its karat lines, when it has them.
SHAPES = {
    'karat lines, wage VAT': (lambda w: _base(
        w, total=3905.0, total_tax=30.0, gold_subtotal=3675.0, wage_subtotal=200.0,
        wage_tax_total=30.0, gold_tax_total=0.0, vat_applied=True, items=[],
        karat_lines=[{'karat': 21, 'weight_grams': 10.0, 'gold_value_cash': 3675.0,
                      'manufacturing_wage_cash': 200.0, 'gold_tax': 0.0, 'wage_tax': 30.0}],
    ), {'21': 10.0}),
    'items only, no VAT': (lambda w: _base(
        w, total=11000.0, total_tax=0.0, gold_subtotal=10000.0, manufacturing_wage_cash=1000.0,
        wage_tax_total=0.0, gold_tax_total=0.0, vat_applied=False,
        items=[{'name': 'سلسال', 'karat': 21, 'weight': 20.0, 'quantity': 1, 'price': 11000.0}],
    ), {'21': 20.0}),
    'the supplier names its gold, two karats': (lambda w: _base(
        w, total=8000.0, total_tax=0.0, gold_subtotal=7500.0, manufacturing_wage_cash=500.0,
        wage_tax_total=0.0, gold_tax_total=0.0, vat_applied=False,
        items=[{'name': 'طقم', 'karat': 21, 'weight': 15.0, 'quantity': 1, 'price': 8000.0}],
        supplier_gold_lines=[{'karat': 21, 'weight': 10.0}, {'karat': 18, 'weight': 6.0}],
    ), {'21': 15.0}),
    'gold VAT and wage VAT': (lambda w: _base(
        w, total=4456.25, total_tax=581.25, gold_subtotal=3675.0, wage_subtotal=200.0,
        wage_tax_total=30.0, gold_tax_total=551.25, vat_applied=True, apply_gold_tax=True,
        items=[],
        karat_lines=[{'karat': 21, 'weight_grams': 10.0, 'gold_value_cash': 3675.0,
                      'manufacturing_wage_cash': 200.0, 'gold_tax': 551.25, 'wage_tax': 30.0}],
    ), {'21': 10.0}),
}


def _moved(invoice_id, account_id):
    """Cash credited and grams credited by karat on the account, by the invoice."""
    cols = [func.coalesce(func.sum(JournalEntryLine.cash_credit - JournalEntryLine.cash_debit), 0)] + [
        func.coalesce(func.sum(getattr(JournalEntryLine, f'credit_{k}k') - getattr(JournalEntryLine, f'debit_{k}k')), 0)
        for k in KARATS]
    row = (db.session.query(*cols).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
           .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                   JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False),
                   JournalEntryLine.account_id == account_id).one())
    cash = round(float(row[0] or 0), 2)
    gold = {k: round(float(v or 0), 3) for k, v in zip(KARATS, row[1:]) if round(float(v or 0), 3)}
    return cash, gold


@pytest.mark.parametrize('shape', list(SHAPES))
def test_the_save_posts_what_the_one_reading_says(auth_headers, world, shape):
    build, items_gold = SHAPES[shape]
    payload = build(world)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=payload)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    invoice_id = resp.get_json()['id']
    db.session.expire_all()

    owed = supplier_purchase_owed(payload, items_gold_by_karat=items_gold)
    cash, gold = _moved(invoice_id, world['accounts'].financial.id)
    _, memo_gold = _moved(invoice_id, world['accounts'].memo.id)
    assert cash == owed.cash, f'{shape}: cash'
    assert memo_gold == {k: round(v, 3) for k, v in owed.gold_by_karat.items()}, f'{shape}: gold'
    assert not gold, 'no gold on the financial account'


# ---- س٢: the preview says, before the save, what the save then does ----

def _balance(supplier):
    """The supplier's balance as the server's reader says it: cash, and grams
    at the main karat (debit minus credit: negative is what we owe)."""
    from pricing.karat_service import by_karat_in_main_karat
    from services.party_live_balances import compute_live_supplier_balances
    db.session.expire_all()
    live = compute_live_supplier_balances([supplier])[supplier.id]
    return (round(float(live['cash']), 2),
            round(by_karat_in_main_karat({k: float(live[k]) for k in ('18k', '21k', '22k', '24k')}), 3))


def _preview(headers, payload):
    resp = flask_app.test_client().post('/api/invoices/purchase-preview', headers=headers, json=payload)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:400]
    return resp.get_json()


def _saved_after_preview(headers, world, payload):
    before = _balance(world['supplier'])
    preview = _preview(headers, payload)
    assert (preview['now']['cash'], preview['now']['gold_main']) == before, 'now is the reader\'s'
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=payload)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    return preview, _balance(world['supplier'])


@pytest.mark.parametrize('shape', list(SHAPES))
def test_the_preview_says_the_balance_the_save_leaves(auth_headers, world, shape):
    build, _ = SHAPES[shape]
    preview, after = _saved_after_preview(auth_headers, world, build(world))
    assert (preview['after']['cash'], preview['after']['gold_main']) == after


def test_the_preview_of_a_cash_payment_with_the_invoice(auth_headers, world):
    method = PaymentMethod(name=f'نقدًا {_uid()}', payment_type='cash')
    db.session.add(method)
    db.session.flush()
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    # The cash owed in full (the wage, 1,000): partial payments are off by default.
    # The wage under every name, as the screen sends it.
    payload.update(settlement_method='partial', amount_paid=1000.0, wage_subtotal=1000.0,
                   wage_cash=1000.0,
                   payments=[{'payment_method_id': method.id, 'amount': 1000.0}])
    preview, after = _saved_after_preview(auth_headers, world, payload)
    assert preview['paid']['cash'] == 1000.0
    assert (preview['after']['cash'], preview['after']['gold_main']) == after


def test_the_preview_of_gold_paid_with_the_invoice(auth_headers, world):
    """5 g of 21 handed back to the supplier from a gold safe, with the invoice."""
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload.update(settlement_method='barter',
                   gold_settlements=[{'safe_box_id': world['display'].id, 'karat': 21, 'weight': 5.0}])
    preview, after = _saved_after_preview(auth_headers, world, payload)
    assert preview['paid']['gold_main'] > 0
    assert (preview['after']['cash'], preview['after']['gold_main']) == after


def test_a_preview_writes_nothing(auth_headers, world):
    build, _ = SHAPES['items only, no VAT']
    before = _balance(world['supplier'])
    _preview(auth_headers, build(world))
    assert _balance(world['supplier']) == before


def test_a_preview_needs_a_named_supplier(auth_headers):
    resp = flask_app.test_client().post('/api/invoices/purchase-preview', headers=auth_headers,
                                        json={'invoice_type': 'شراء', 'items': []})
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'supplier_required'


# ---- one wage: the one the supplier's entry posts (ADR-060 Known follow-ups) ----
# The payment check and the invoice's stored wage read wage_subtotal alone, the
# supplier's entry manufacturing_wage_cash first: a wage named only the second
# way was posted to the supplier, and the invoice neither took its payment nor
# knew it was owed.

def _cash_method():
    method = PaymentMethod(name=f'نقدًا {_uid()}', payment_type='cash')
    db.session.add(method)
    db.session.flush()
    return method


def test_a_wage_named_as_the_entry_reads_it_is_paid_and_kept(auth_headers, world):
    method = _cash_method()
    build, _ = SHAPES['items only, no VAT']   # the wage as manufacturing_wage_cash only
    payload = build(world)
    assert 'wage_subtotal' not in payload
    payload.update(settlement_method='partial', amount_paid=1000.0,
                   payments=[{'payment_method_id': method.id, 'amount': 1000.0}])
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=payload)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    db.session.expire_all()
    invoice = db.session.get(Invoice, resp.get_json()['id'])
    assert invoice.wage_subtotal == 1000.0
    assert invoice.cash_obligation == 1000.0
    assert invoice.status == 'paid'


def test_when_the_names_differ_the_invoice_wage_is_the_posted_one(auth_headers, world):
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload['wage_subtotal'] = 800.0   # the entry posts manufacturing_wage_cash, 1,000
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=payload)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    db.session.expire_all()
    cash, _ = _moved(resp.get_json()['id'], world['accounts'].financial.id)
    invoice = db.session.get(Invoice, resp.get_json()['id'])
    assert cash == 1000.0
    assert invoice.wage_subtotal == 1000.0
    assert invoice.cash_obligation == 1000.0
