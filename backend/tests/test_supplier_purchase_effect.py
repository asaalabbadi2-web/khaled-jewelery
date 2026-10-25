"""What a supplier purchase adds to the supplier is said in one place, and the save posts it (ADR-060 follow-up, option أ).

services/supplier_purchase_effect.py reads the request once: the cash the
supplier is owed (the gold's VAT, the wage and its VAT, priced stones) and its
gold by karat. The save takes its supplier lines' amounts from it, and the
purchase preview says them -- so what is previewed is what is posted.

The law: for every shape of a purchase request, the save's cash credit on the
supplier's financial account and its gold credits on the supplier's memo
account are exactly what supplier_purchase_owed says.

Run:
    python -m pytest tests/test_supplier_purchase_effect.py -v
"""
import uuid
from datetime import datetime

import pytest
from sqlalchemy import func

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, SafeBox, Settings, Supplier, db
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
    accounts = ensure_supplier_accounts(supplier)
    db.session.flush()
    from accounting.mappings import _ACCOUNT_NUMBER_CACHE
    for n in ('1320', '1400'):
        _ACCOUNT_NUMBER_CACHE.pop(n, None)
    return {'supplier': supplier, 'accounts': accounts}


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
