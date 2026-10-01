"""An office reservation is a purchase: the gold bought is added at the office, at settlement (SAFEBOX-001, the owner 1 Oct 2026).

The owner: every closing-office reservation is a purchase -- we never send our
scrap to the office -- and once it is settled the gold stays at the office as
our debt, on our account's safe there, until a receipt voucher brings it to
the scrap safe or a payment voucher pays another supplier with it.

The old entry, written when the reservation was CREATED, debited the office's
weight account and credited scrap inventory (71310): it moved gold from our
scrap to the office and added none -- the scrap inventory group stood near
-4.8 kg on the 30 Sep copy.

The laws:
  - creating a reservation moves no gold;
  - settling it debits the office's weight account and credits the weight
    twin of the purchases account the settlement debits (512 -> 7512), in the
    settlement's own entry -- scrap inventory is not touched; the office safe's
    statement shows the same grams;
  - rejecting the settled invoice takes that gold back off the office;
  - with no weight twin for the purchases account, settlement is refused --
    a purchase whose gold cannot be recorded is not recorded at all.

Run:
    python -m pytest tests/test_office_reservation_is_a_purchase.py -v
"""
import uuid

import pytest
from sqlalchemy import func

from app import app as flask_app
from models import (
    Account, JournalEntry, JournalEntryLine, Office, OfficeReservation, SafeBox, SafeBoxTransaction,
    Supplier, db,
)

GRAMS = 12.5


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


def _acc(number, name, kind, tx='cash', weight=False):
    a = Account.query.filter_by(account_number=number).first()
    if a is None:
        a = Account(account_number=number, name=name, type=kind, transaction_type=tx, tracks_weight=weight)
        db.session.add(a)
        db.session.flush()
    return a


@pytest.fixture
def rworld():
    """As in production: the office's financial account carries a weight twin,
    and our account's safe at the office is on it; 512 carries 7512."""
    purchases = _acc('512', 'مشتريات ذهب كسر', 'Expense')
    twin = _acc('7512', 'مشتريات ذهب كسر وزني', 'Expense', tx='gold', weight=True)
    purchases.memo_account_id = twin.id
    scrap = _acc('71310', 'مخزون الذهب ـ كسر وزني', 'Asset', tx='gold', weight=True)
    office_cash = Account(account_number=f'21{uuid.uuid4().int % 10**6:06d}', name=f'مكتب {_uid()}',
                          type='Liability', transaction_type='cash')
    office_gold = Account(account_number=f'721{uuid.uuid4().int % 10**5:05d}', name=f'مكتب وزني {_uid()}',
                          type='Liability', transaction_type='gold', tracks_weight=True)
    db.session.add_all([office_cash, office_gold])
    db.session.flush()
    office_cash.memo_account_id = office_gold.id
    office_safe = SafeBox(name=f'حسابنا بالمكتب {_uid()}', safe_type='gold', account_id=office_gold.id, is_active=True)
    supplier = Supplier(supplier_code=f'SUPR-{_uid()}', name=f'مورد مكتب {_uid()}')
    db.session.add_all([office_safe, supplier])
    db.session.flush()
    office = Office(office_code=f'OFR-{_uid()}', name=f'مكتب تسكير {_uid()}', active=True,
                    account_category_id=office_cash.id, supplier_id=supplier.id)
    db.session.add(office)
    db.session.flush()
    return {'office': office, 'office_gold': office_gold, 'office_safe': office_safe,
            'twin': twin, 'scrap': scrap, 'purchases': purchases}


def _create(headers, w):
    resp = flask_app.test_client().post('/api/office-reservations', headers=headers, json={
        'office_id': w['office'].id, 'weight': GRAMS, 'karat': 21, 'price_per_gram': 400.0,
        'execution_price_per_gram': 400.0, 'paid_amount': 0})
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]
    return resp.get_json()['id']


def _settle(headers, rid):
    return flask_app.test_client().post(f'/api/office-reservations/{rid}/settle', headers=headers,
                                        json={'execution_price_per_gram': 400.0})


def _grams(account, rid=None):
    """21k grams the posted entries put on *account* (debit minus credit)."""
    q = (db.session.query(func.coalesce(func.sum(JournalEntryLine.debit_21k - JournalEntryLine.credit_21k), 0))
         .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(JournalEntryLine.account_id == account.id, JournalEntry.is_posted.is_(True),
                 JournalEntry.is_deleted.is_(False)))
    return round(float(q.scalar() or 0), 3)


def _statement(safe):
    rows = SafeBoxTransaction.query.filter_by(safe_box_id=safe.id).all()
    return round(sum((1 if r.direction == 'in' else -1) * float(r.weight_21k or 0) for r in rows), 3)


def _books(w):
    db.session.expire_all()
    return {'office': _grams(w['office_gold']), 'office_safe': _statement(w['office_safe']),
            'purchases_weight': _grams(w['twin']), 'scrap_inventory': _grams(w['scrap'])}


def test_creating_a_reservation_moves_no_gold(auth_headers, rworld):
    before = _books(rworld)
    _create(auth_headers, rworld)
    assert _books(rworld) == before


def test_settling_adds_the_bought_gold_at_the_office(auth_headers, rworld):
    before = _books(rworld)
    rid = _create(auth_headers, rworld)
    resp = _settle(auth_headers, rid)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    after = _books(rworld)
    assert {k: round(after[k] - before[k], 3) for k in after} == {
        'office': GRAMS, 'office_safe': GRAMS, 'purchases_weight': -GRAMS, 'scrap_inventory': 0.0}


def test_rejecting_the_settled_invoice_takes_the_gold_back(auth_headers, rworld):
    before = _books(rworld)
    rid = _create(auth_headers, rworld)
    invoice_id = _settle(auth_headers, rid).get_json()['purchase_invoice_id']
    resp = flask_app.test_client().post(f'/api/invoices/{invoice_id}/reject', headers=auth_headers,
                                        json={'reason': 'law'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _books(rworld) == before


def test_a_settlement_with_no_weight_twin_is_refused(auth_headers, rworld):
    rworld['purchases'].memo_account_id = None
    db.session.flush()
    rid = _create(auth_headers, rworld)
    before = _books(rworld)
    resp = _settle(auth_headers, rid)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'reservation_weight_accounts_missing'
    db.session.expire_all()
    assert db.session.get(OfficeReservation, rid).purchase_invoice_id is None
    assert _books(rworld) == before
