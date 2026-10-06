"""Manufacturing wages follow the company's setting, and a purchase and a sale agree (ADR-039, WAGE-MODE-1).

Found 6 Oct 2026: the supplier-purchase posting read manufacturing_wage_mode,
resolved an expense account from it, and used neither -- it always debited
1320 «مخزون أجور المصنعية». On the 6 Oct production copy the setting says
`expense` and 158 purchases record `expense`, while their entries put
541,514.97 on 1320. A sale always credited 1320.

The owner (6 Oct 2026): capitalize at purchase and expense at sale is this
company's rule, not every company's; another may expense wages at purchase,
and then nothing is released at sale.

The law:
  - inventory: a purchase debits 1320; a sale moves the wage from 1320 to the
    wage expense.
  - expense: a purchase debits the wage expense; a sale does not touch 1320.
  - an invoice's entry follows the mode frozen on it at creation, not the live
    setting.

Run:
    python -m pytest tests/test_wage_treatment_follows_the_setting.py -v
"""
import uuid
from datetime import datetime

import pytest
from sqlalchemy import func

from accounting.mappings import _ACCOUNT_NUMBER_CACHE
from app import app as flask_app
from models import (
    Account, Invoice, JournalEntry, JournalEntryLine, SafeBox, Settings, Supplier, db,
)
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)

WAGE_ACCOUNTS = ('1320', '1350', '510')


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    # The number cache outlives a rolled-back account; start and end clean.
    for n in WAGE_ACCOUNTS:
        _ACCOUNT_NUMBER_CACHE.pop(n, None)
    yield
    for n in WAGE_ACCOUNTS:
        _ACCOUNT_NUMBER_CACHE.pop(n, None)


def _uid():
    return uuid.uuid4().hex[:6]


@pytest.fixture
def books():
    """As production: 1320 holds capitalized wages, 510 is the wage expense,
    the display stock keeps its weight on a memo account, VAT goes to 1400."""
    from party_account_service import ensure_supplier_accounts

    def account(number, name, type_):
        acc = Account.query.filter_by(account_number=number).first()
        if not acc:
            acc = Account(account_number=number, name=name, type=type_)
            db.session.add(acc)
            db.session.flush()
        return acc

    wage_inventory = account('1320', 'مخزون أجور المصنعية', 'Asset')
    wage_expense = account('510', 'مصروفات أجور المصنعية', 'expense')
    account('1400', 'ضريبة مدفوعة على المشتريات', 'Asset')

    stock = Account.query.filter_by(account_number='1300').one()
    memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}',
                   name=f'مخزون معروض وزني {_uid()}', type='Asset', tracks_weight=True)
    db.session.add(memo)
    db.session.flush()
    stock.memo_account_id = memo.id
    db.session.add(SafeBox(name=f'المعروض {_uid()}', safe_type='gold',
                           account_id=memo.id, is_active=True))
    supplier = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}',
                        default_wage_type='cash')
    db.session.add(supplier)
    db.session.flush()
    ensure_supplier_accounts(supplier)
    db.session.flush()
    return {'wage_inventory': wage_inventory, 'wage_expense': wage_expense,
            'supplier': supplier}


def _settings(mode, *, auto_post=True):
    row = Settings.query.first() or Settings()
    row.manufacturing_wage_mode = mode
    row.auto_post_invoices = auto_post
    row.allow_partial_invoice_payments = True
    db.session.add(row)
    db.session.flush()


def _create(headers, payload):
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=payload)
    assert resp.status_code == 201, resp.get_json()
    return resp.get_json()


def _purchase(b, wage=200.0):
    """10 g of 21k at 3,675.00, wages 200.00 + VAT 30.00, on credit."""
    gold, vat = 3675.0, round(wage * 0.15, 2)
    return {
        'invoice_type': 'شراء', 'supplier_id': b['supplier'].id, 'gold_type': 'new',
        'date': datetime.now().isoformat(),
        'total': gold + wage + vat, 'total_tax': vat,
        'gold_subtotal': gold, 'wage_subtotal': wage,
        'wage_tax_total': vat, 'gold_tax_total': 0.0,
        'settlement_method': 'credit', 'amount_paid': 0.0,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1,
                   'manufacturing_wage_per_gram': wage / 10.0}],
    }


def _sale(w, wage_per_gram=10.0):
    """2 g of 21k sold on credit with a wage of 10.00 a gram: 20.00 of wage."""
    payload = _payload(w, 'sale_on_credit', held=False)
    payload['items'][0]['wage'] = wage_per_gram
    return payload


def _moved(invoice_id, account):
    """Cash debit and credit the invoice's entries put on [account]."""
    db.session.expire_all()
    dr, cr = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_debit), 0),
                               func.coalesce(func.sum(JournalEntryLine.cash_credit), 0))
              .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
              .filter(JournalEntry.reference_type == 'invoice',
                      JournalEntry.reference_id == invoice_id,
                      JournalEntry.is_deleted.is_(False),
                      JournalEntryLine.is_deleted.is_(False),
                      JournalEntryLine.account_id == account.id).one())
    return round(float(dr), 2), round(float(cr), 2)


# ── inventory: what production does today ──────────────────────────────────

def test_capitalized_a_purchase_puts_its_wages_on_wage_inventory(auth_headers, books):
    _settings('inventory')
    inv = _create(auth_headers, _purchase(books))
    assert _moved(inv['id'], books['wage_inventory']) == (200.0, 0.0)
    assert _moved(inv['id'], books['wage_expense']) == (0.0, 0.0)


def test_capitalized_a_sale_moves_its_wage_from_wage_inventory_to_expense(auth_headers, books, world):
    _settings('inventory')
    inv = _create(auth_headers, _sale(world))
    assert _moved(inv['id'], books['wage_inventory']) == (0.0, 20.0)
    assert _moved(inv['id'], books['wage_expense']) == (20.0, 0.0)


# ── expense: another company's choice ──────────────────────────────────────

def test_expensed_a_purchase_charges_its_wages_to_the_wage_expense(auth_headers, books):
    _settings('expense')
    inv = _create(auth_headers, _purchase(books))
    assert _moved(inv['id'], books['wage_expense']) == (200.0, 0.0)
    assert _moved(inv['id'], books['wage_inventory']) == (0.0, 0.0)
    assert db.session.get(Invoice, inv['id']).manufacturing_wage_mode_snapshot == 'expense'


def test_expensed_a_sale_does_not_touch_wage_inventory(auth_headers, books, world):
    _settings('expense')
    inv = _create(auth_headers, _sale(world))
    assert _moved(inv['id'], books['wage_inventory']) == (0.0, 0.0)
    assert _moved(inv['id'], books['wage_expense']) == (0.0, 0.0)


# ── frozen, not live (§13) ─────────────────────────────────────────────────

def test_a_purchase_posted_later_keeps_the_treatment_it_was_created_under(auth_headers, books):
    _settings('inventory', auto_post=False)
    inv = _create(auth_headers, _purchase(books))
    assert inv['is_posted'] is False

    _settings('expense', auto_post=False)
    resp = flask_app.test_client().post(f'/api/invoices/post/{inv["id"]}',
                                        headers=auth_headers, json={})
    assert resp.status_code == 200, resp.get_json()

    assert _moved(inv['id'], books['wage_inventory']) == (200.0, 0.0)
    assert _moved(inv['id'], books['wage_expense']) == (0.0, 0.0)


# ── the setting itself ─────────────────────────────────────────────────────

def test_the_settings_refuse_a_treatment_that_is_neither(auth_headers, books):
    _settings('inventory')
    resp = flask_app.test_client().put('/api/settings', headers=auth_headers,
                                       json={'manufacturing_wage_mode': 'capitalise'})
    assert resp.status_code == 400, resp.get_json()
    db.session.expire_all()
    assert Settings.query.first().manufacturing_wage_mode == 'inventory'


def test_the_wage_treatment_reads_the_wage_inventory_and_its_balance(auth_headers, books):
    """What the settings screen shows before a change: the treatment, the
    account capitalized wages sit on, and its posted balance."""
    _settings('inventory')

    def read():
        resp = flask_app.test_client().get('/api/settings/wage-treatment',
                                           headers=auth_headers)
        assert resp.status_code == 200, resp.get_json()
        return resp.get_json()

    before = read()
    assert before['mode'] == 'inventory'
    assert before['wage_inventory_account']['account_number'] == '1320'

    _create(auth_headers, _purchase(books))
    after = read()
    assert round(after['wage_inventory_account']['balance'] - before['wage_inventory_account']['balance'], 2) == 200.0


def test_the_wage_treatment_is_not_read_without_permission(books):
    resp = flask_app.test_client().get('/api/settings/wage-treatment')
    assert resp.status_code == 401


# ── the release's correction (alembic 20261006_wage_mode_matches_books) ─────

def _migration():
    import importlib.util
    import pathlib
    path = (pathlib.Path(__file__).resolve().parent.parent / 'alembic' / 'versions'
            / '20261006_wage_mode_matches_books.py')
    spec = importlib.util.spec_from_file_location('wage_mode_matches_books', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_a_setting_that_lies_about_capitalized_books_is_corrected(auth_headers, books):
    """Production: the setting says expense, the posted purchases capitalized."""
    _settings('inventory')
    _create(auth_headers, _purchase(books))          # posted onto 1320
    _settings('expense')

    before, after, evidence = _migration().correct_wage_mode(db.session.connection())

    assert (before, after) == ('expense', 'inventory')
    assert evidence >= 1
    db.session.expire_all()
    assert Settings.query.first().manufacturing_wage_mode == 'inventory'


def test_a_company_with_no_capitalized_purchase_keeps_its_choice(books):
    """A new company chose expense: there is nothing in the books to say otherwise."""
    migration = _migration()
    if migration.capitalized_purchase_lines(db.session.connection()):
        pytest.skip('the test database already holds capitalized purchases')
    _settings('expense')

    before, after, evidence = migration.correct_wage_mode(db.session.connection())

    assert (before, after, evidence) == ('expense', 'expense', 0)
    db.session.expire_all()
    assert Settings.query.first().manufacturing_wage_mode == 'expense'
