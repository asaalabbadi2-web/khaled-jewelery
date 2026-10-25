"""A supplier's wage is owed in cash, always (ADR-061).

The owner, 25 Oct 2026: «الأجرة دائمًا نقد حتى وإن كانت ذهبًا: تُحوَّل إلى نقد
وتُسجَّل نقدًا». A wage paid in gold is a later settlement of a cash debt, not a
debt in gold.

Measured before (ADR-060's discovery): a supplier set to take its wage in gold
(default_wage_type='gold') had its purchase post the wage twice -- 1,000 SAR
cash on its financial account AND the wage as gold (3.511 g of 21 at the
price) on its memo account -- and the entry, unbalanced by that weight, was
refused: no purchase from such a supplier could be saved. No supplier used it
(27 suppliers, all cash, on the 5 Oct copy), but the supplier screen offered it.

The law:
  - a purchase from a supplier, whatever its old flag, saves; its wage (and the
    wage's VAT) is a cash credit on the supplier's financial account, and its
    memo account carries the purchase's gold alone;
  - the cash an invoice can be paid counts the wage, whatever the flag;
  - a supplier is not set to take its wage in gold: the server refuses it.

Run:
    python -m pytest tests/test_supplier_wage_is_cash.py -v
"""
import uuid
from datetime import datetime

import pytest
from sqlalchemy import func

from app import app as flask_app
from models import (
    Account, GoldPrice, JournalEntry, JournalEntryLine, Supplier, db,
    purchase_cash_obligation,
)


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
    """As in production: the display stock (1300) keeps its weight on a memo
    account; a gold price is known (it converted the wage to gold)."""
    from party_account_service import ensure_supplier_accounts
    db.session.add(GoldPrice(price=2700.0, date=datetime.now()))
    stock = Account.query.filter_by(account_number='1300').one()
    memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}', name=f'مخزون معروض وزني {_uid()}',
                   type='Asset', tracks_weight=True)
    db.session.add(memo)
    db.session.flush()
    stock.memo_account_id = memo.id

    def supplier(wage_type):
        s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}', default_wage_type=wage_type)
        db.session.add(s)
        db.session.flush()
        accounts = ensure_supplier_accounts(s)
        db.session.flush()
        return s, accounts

    return supplier


def _purchase(supplier_id):
    """20 g of 21k, a wage of 1,000 SAR."""
    return {
        'invoice_type': 'شراء', 'supplier_id': supplier_id, 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'total': 11000.0,
        'gold_subtotal': 10000.0, 'manufacturing_wage_cash': 1000.0,
        'wage_tax_total': 0.0, 'gold_tax_total': 0.0, 'total_tax': 0.0,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 20.0, 'quantity': 1, 'price': 11000.0}],
    }


def _moved(invoice_id, account_id):
    """Cash credited, and grams of 21 credited, on the account by the invoice."""
    row = (db.session.query(
        func.coalesce(func.sum(JournalEntryLine.cash_credit - JournalEntryLine.cash_debit), 0),
        func.coalesce(func.sum(JournalEntryLine.credit_21k - JournalEntryLine.debit_21k), 0),
    ).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False),
                JournalEntryLine.account_id == account_id).one())
    return round(float(row[0] or 0), 2), round(float(row[1] or 0), 3)


@pytest.mark.parametrize('flag', ['cash', 'gold'])
def test_a_purchase_owes_its_wage_in_cash_whatever_the_supplier_flag(auth_headers, world, flag):
    supplier, accounts = world(flag)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=_purchase(supplier.id))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    invoice_id = resp.get_json()['id']
    db.session.expire_all()

    assert _moved(invoice_id, accounts.financial.id) == (1000.0, 0.0), 'the wage, in cash'
    assert _moved(invoice_id, accounts.memo.id) == (0.0, 20.0), 'the gold bought, and no wage in gold'


@pytest.mark.parametrize('flag', ['cash', 'gold'])
def test_the_cash_an_invoice_can_be_paid_counts_the_wage(world, flag):
    supplier, _ = world(flag)
    assert purchase_cash_obligation(
        invoice_type='شراء', office_id=None, total=50000.0, wage_subtotal=2491.0,
        wage_tax_total=373.65, gold_tax_total=0.0, supplier=supplier,
    ) == 2864.65


def test_a_supplier_is_not_set_to_take_its_wage_in_gold(auth_headers):
    client = flask_app.test_client()
    resp = client.post('/api/suppliers', headers=auth_headers, json={
        'name': f'مورد {_uid()}', 'default_wage_type': 'gold', 'force': True,
    })
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json().get('error') == 'wage_is_cash'


def test_an_existing_supplier_is_not_turned_to_a_gold_wage(auth_headers, world):
    supplier, _ = world('cash')
    resp = flask_app.test_client().put(f'/api/suppliers/{supplier.id}', headers=auth_headers, json={
        'default_wage_type': 'gold',
    })
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json().get('error') == 'wage_is_cash'
    db.session.expire_all()
    assert db.session.get(Supplier, supplier.id).default_wage_type == 'cash'


def test_a_supplier_saved_with_a_cash_wage_is_as_before(auth_headers):
    resp = flask_app.test_client().post('/api/suppliers', headers=auth_headers, json={
        'name': f'مورد {_uid()}', 'default_wage_type': 'cash', 'force': True,
    })
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]
