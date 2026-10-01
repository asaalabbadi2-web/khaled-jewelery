"""A supplier purchase's gold row is where its entry put the gold -- and a reservation's is the reservation's (SAFEBOX-001 S1).

Measured on the 30 Sep copy (docs/plans/safebox-001-s0-ledger-writers-map.md):

  - a supplier purchase of new gold posted at creation wrote no gold row at
    all: the entry moved the gold into the display stock account (the display
    safe's), the safe's statement nothing -- 78 invoices since May. Its rows
    before May were one-off backfills and repairs; no live path ever wrote one.
  - a scrap purchase settled by a closing-office reservation got, when posted
    later, a gold row INTO the display safe -- the default safe -- though its
    gold is the reservation's: it stays at the office as our debt, on our
    account's safe there, and reaches the scrap safe only by a receipt voucher
    (the owner, 1 Oct 2026). 17 invoices, 3,388.8 g that are not there.

The law: for a supplier purchase (and a supplier return), every gold safe's
statement rows for the invoice equal what its posted entry moved on that
safe's account -- posted at creation or later; and an invoice a reservation
settled gets no gold row from posting.

Run:
    python -m pytest tests/test_supplier_purchase_gold_follows_its_entry.py -v
"""
import uuid
from datetime import datetime

import pytest
from sqlalchemy import func

from app import app as flask_app
from models import (
    Account, Invoice, InvoiceKaratLine, JournalEntry, JournalEntryLine, Office, OfficeReservation,
    SafeBox, SafeBoxTransaction, Settings, Supplier, db,
)

KARATS = ('18k', '21k', '22k', '24k')


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
def pworld():
    """As in production: the display stock account (1300) keeps its weight on a
    memo account, and the display safe is that memo account's."""
    from party_account_service import ensure_supplier_accounts
    stock = Account.query.filter_by(account_number='1300').one()
    memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}', name=f'مخزون معروض وزني {_uid()}',
                   type='Asset', tracks_weight=True)
    db.session.add(memo)
    db.session.flush()
    stock.memo_account_id = memo.id
    display = SafeBox(name=f'المعروض {_uid()}', safe_type='gold', account_id=memo.id, is_active=True)
    supplier = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add_all([display, supplier])
    db.session.flush()
    ensure_supplier_accounts(supplier)
    db.session.flush()
    return {'display': display, 'supplier': supplier}


def _auto_post(on):
    row = Settings.query.first() or Settings()
    row.auto_post_invoices = on
    db.session.add(row)
    db.session.flush()


def _create(headers, payload):
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=payload)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    return resp.get_json()


def _purchase(w, grams=10.0):
    return {'invoice_type': 'شراء', 'supplier_id': w['supplier'].id, 'gold_type': 'new',
            'date': datetime.now().isoformat(), 'total': 1000.0,
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': grams, 'quantity': 1, 'price': 1000.0}]}


def _statement_and_entry(invoice_id):
    """Per gold safe: its statement rows for the invoice, and what the invoice's
    posted entries moved on its account -- grams per karat, in minus out."""
    db.session.expire_all()
    out = {}
    for t in SafeBoxTransaction.query.filter(SafeBoxTransaction.invoice_id == invoice_id).all():
        sb = db.session.get(SafeBox, t.safe_box_id)
        if (sb.safe_type or '') != 'gold':
            continue
        sign = 1 if t.direction == 'in' else -1
        for k in KARATS:
            v = sign * float(getattr(t, f'weight_{k}') or 0)
            if v:
                key = (sb.id, k)
                out.setdefault(key, [0.0, 0.0])[0] += v
    for sb in SafeBox.query.filter(SafeBox.safe_type == 'gold').all():
        cols = [func.coalesce(func.sum(getattr(JournalEntryLine, f'debit_{k}') - getattr(JournalEntryLine, f'credit_{k}')), 0)
                for k in KARATS]
        row = (db.session.query(*cols).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
               .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                       JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False),
                       JournalEntryLine.is_deleted.is_(False), JournalEntryLine.account_id == sb.account_id).one())
        for k, v in zip(KARATS, row):
            if float(v or 0):
                out.setdefault((sb.id, k), [0.0, 0.0])[1] += float(v)
    return {key: [round(a, 3), round(b, 3)] for key, (a, b) in out.items()}


def _agrees(invoice_id):
    pairs = _statement_and_entry(invoice_id)
    assert pairs, 'the entry moved no gold safe -- the world is not as in production'
    return {key: v for key, v in pairs.items() if v[0] != v[1]}


def test_a_purchase_posted_at_creation_records_its_gold_where_its_entry_put_it(auth_headers, pworld):
    _auto_post(True)
    inv = _create(auth_headers, _purchase(pworld))
    assert inv['is_posted'] is True
    assert _agrees(inv['id']) == {}
    assert _statement_and_entry(inv['id'])[(pworld['display'].id, '21k')] == [10.0, 10.0]


def test_a_purchase_posted_later_records_the_same(auth_headers, pworld):
    _auto_post(False)
    inv = _create(auth_headers, _purchase(pworld))
    assert inv['is_posted'] is False
    resp = flask_app.test_client().post(f'/api/invoices/post/{inv["id"]}', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _agrees(inv['id']) == {}


def test_a_supplier_return_records_its_gold_where_its_entry_took_it(auth_headers, pworld):
    from models import InvoiceItem
    _auto_post(True)
    original = _create(auth_headers, _purchase(pworld))
    item = InvoiceItem.query.filter_by(invoice_id=original['id']).first()
    ret = _create(auth_headers, {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': pworld['supplier'].id, 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'original_invoice_id': original['id'], 'amount_paid': 0, 'total': 1000.0,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1, 'price': 1000.0,
                   'original_invoice_item_id': item.id}]})
    assert _agrees(ret['id']) == {}
    assert _statement_and_entry(ret['id'])[(pworld['display'].id, '21k')] == [-10.0, -10.0]


def test_a_purchase_a_reservation_settled_gets_no_gold_row_from_posting(auth_headers, pworld):
    """Its gold is the reservation's: on our account's safe at the office."""
    office = Office(office_code=f'OF-{_uid()}', name=f'مكتب تسكير {_uid()}')
    db.session.add(office)
    db.session.flush()
    inv = Invoice(invoice_type_id=900000 + uuid.uuid4().int % 99999, invoice_type='شراء', gold_type='scrap',
                  supplier_id=pworld['supplier'].id, office_id=office.id, date=datetime.now(), total=64500.0,
                  status='unpaid', amount_paid=0.0, is_posted=False)
    db.session.add(inv)
    db.session.flush()
    db.session.add_all([
        InvoiceKaratLine(invoice_id=inv.id, karat=21, weight_grams=122.55, gold_value_cash=64500.0,
                         manufacturing_wage_cash=0.0),
        OfficeReservation(office_id=office.id, reservation_code=f'RES-{_uid()}', karat=21, weight_grams=122.55,
                          weight_main_karat=122.55, price_per_gram=526.3, execution_price_per_gram=526.3,
                          total_amount=64500.0, purchase_invoice_id=inv.id),
    ])
    db.session.flush()
    resp = flask_app.test_client().post(f'/api/invoices/post/{inv.id}', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    rows = SafeBoxTransaction.query.filter(SafeBoxTransaction.ref_id == inv.id,
                                           SafeBoxTransaction.ref_type.like('invoice_gold%')).all()
    assert [(r.safe_box_id, r.direction) for r in rows] == []
