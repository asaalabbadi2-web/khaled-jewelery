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
  - settling it debits the office's deposit -- ours, held for us (ADR-052;
    it was the office's supplier weight account, a liability) -- and credits the weight
    twin of the purchases account the settlement debits (512 -> 7512), in the
    settlement's own entry -- scrap inventory is not touched; the office safe's
    statement shows the same grams;
  - rejecting the settled invoice takes that gold back off the office;
  - with no weight twin for the purchases account, settlement is refused --
    a purchase whose gold cannot be recorded is not recorded at all;
  - with no deposit for the office, settlement is refused by name -- no
    fallback to its supplier weight account.

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
    """As in production after ADR-052: the office's financial account carries a
    weight twin (its supplier account), and the office's deposit -- its
    supplier's gold safe -- is an asset of ours; 512 carries 7512."""
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
    deposit = Account(account_number=f'7133{uuid.uuid4().int % 10**5:05d}', name=f'ذهب مودع لدى مكتب {_uid()}',
                      type='Asset', transaction_type='gold', tracks_weight=True)
    db.session.add(deposit)
    db.session.flush()
    office_safe = SafeBox(name=f'ذهب مودع لدى مكتب {_uid()}', safe_type='gold', account_id=deposit.id,
                          is_active=True, stock_location='deposit')
    db.session.add(office_safe)
    db.session.flush()
    supplier = Supplier(supplier_code=f'SUPR-{_uid()}', name=f'مورد مكتب {_uid()}',
                        default_safe_box_id=office_safe.id)
    db.session.add(supplier)
    db.session.flush()
    office = Office(office_code=f'OFR-{_uid()}', name=f'مكتب تسكير {_uid()}', active=True,
                    account_category_id=office_cash.id, supplier_id=supplier.id)
    db.session.add(office)
    db.session.flush()
    return {'office': office, 'office_gold': deposit, 'supplier_gold': office_gold, 'office_safe': office_safe,
            'supplier': supplier,
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
            'supplier_account': _grams(w['supplier_gold']),
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
        'office': GRAMS, 'office_safe': GRAMS, 'supplier_account': 0.0, 'purchases_weight': -GRAMS,
        'scrap_inventory': 0.0}


def _unsettle(headers, rid):
    return flask_app.test_client().post(f'/api/office-reservations/{rid}/unsettle', headers=headers,
                                        json={'reason': 'law'})


def test_undoing_the_execution_takes_the_gold_back(auth_headers, rworld):
    """«إلغاء التنفيذ» (ADR-052): the execution approves its purchase, so its
    undoing unposts and rejects it in one operation -- the books as before, the
    reservation open, the invoice rejected."""
    from models import Invoice
    before = _books(rworld)
    rid = _create(auth_headers, rworld)

    def standing():
        db.session.expire_all()
        r = db.session.get(OfficeReservation, rid)
        return (r.purchase_invoice_id, r.status, r.weight_consumed_main_karat,
                r.weight_remaining_main_karat, r.executions_created)

    open_as_made = standing()
    invoice_id = _settle(auth_headers, rid).get_json()['purchase_invoice_id']
    resp = _unsettle(auth_headers, rid)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _books(rworld) == before
    # Open as it was made -- not «pending» with its weight read as consumed
    # (RES-0038 on the 20 Oct rehearsal: 5 g consumed, 0 left, no invoice).
    assert standing() == open_as_made
    invoice = db.session.get(Invoice, invoice_id)
    assert (invoice.is_posted, invoice.status) == (False, 'rejected')


def test_an_execution_done_again_is_undone_again(auth_headers, rworld):
    """Undone and done again, it has two gold entries: the undoing reverses the latest."""
    before = _books(rworld)
    rid = _create(auth_headers, rworld)
    assert _settle(auth_headers, rid).status_code == 200
    assert _unsettle(auth_headers, rid).status_code == 200
    assert _settle(auth_headers, rid).status_code == 200
    assert _books(rworld)['office'] == round(before['office'] + GRAMS, 3)
    assert _unsettle(auth_headers, rid).status_code == 200
    assert _books(rworld) == before


def test_a_deposit_spent_since_cannot_be_undone(auth_headers, rworld):
    """The gold paid on to a supplier since: undoing would leave the deposit below zero."""
    import datetime as dt
    rid = _create(auth_headers, rworld)
    assert _settle(auth_headers, rid).status_code == 200
    je = JournalEntry(entry_number=f'JE-SP-{_uid()}', date=dt.datetime(2026, 10, 19), description='صرف من الوديعة',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=rworld['office_gold'].id,
                                    description='صرف لمورد', credit_21k=GRAMS))
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=rworld['scrap'].id,
                                    description='مقابل', debit_21k=GRAMS))
    db.session.flush()
    resp = _unsettle(auth_headers, rid)
    assert resp.status_code == 409, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'deposit_already_used'
    # The route rolls back its transaction -- the fence's flushed spend with it --
    # so the books are not compared here; the execution stands.
    db.session.expire_all()
    assert db.session.get(OfficeReservation, rid).purchase_invoice_id is not None


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


def test_a_settled_reservation_opens_no_weight_closing_order_for_its_purchase(auth_headers, rworld):
    """A purchase closes riyals; it opens none (ADR-048, the owner 16 Oct 2026).
    The settlement opened an order for its own purchase invoice, as if a sale:
    on the 15 Oct copy 33 such orders (6,532.8 g), and eight executions closed
    one purchase against another -- one of them, 26 Feb, its own."""
    from models import OfficeReservation, WeightClosingOrder
    rid = _create(auth_headers, rworld)
    assert _settle(auth_headers, rid).status_code == 200
    db.session.expire_all()
    purchase_id = db.session.get(OfficeReservation, rid).purchase_invoice_id
    assert purchase_id
    assert WeightClosingOrder.query.filter_by(invoice_id=purchase_id).count() == 0


def test_an_office_with_no_deposit_is_refused_by_name(auth_headers, rworld):
    """The gold bought goes to the office's deposit or nowhere (ADR-052): not
    silently to its supplier weight account, which read it as the office's debt."""
    rworld['supplier'].default_safe_box_id = None
    db.session.flush()
    rid = _create(auth_headers, rworld)
    before = _books(rworld)
    resp = _settle(auth_headers, rid)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'office_has_no_deposit'
    assert rworld['office'].name in resp.get_json()['message']
    db.session.expire_all()
    assert db.session.get(OfficeReservation, rid).purchase_invoice_id is None
    assert _books(rworld) == before


def test_the_execution_approves_its_purchase(auth_headers, rworld):
    """The owner (19 Oct 2026): the execution approves the invoice -- its gold
    enters the deposit posted, so the purchase is not left waiting while the
    gold is usable and the weight close cannot see it."""
    from models import Invoice
    rid = _create(auth_headers, rworld)
    resp = _settle(auth_headers, rid)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    invoice = db.session.get(Invoice, resp.get_json()['purchase_invoice_id'])
    assert invoice.is_posted is True and invoice.posted_by


def test_executing_needs_the_right_to_approve_invoices():
    """Who executes approves (the owner, 19 Oct 2026): the right to approve invoices."""
    import pathlib
    src = (pathlib.Path(__file__).resolve().parent.parent / 'routes' / 'office_reservations.py').read_text(encoding='utf-8')
    head = src[src.index("'/office-reservations/<int:reservation_id>/settle'"):src.index('def settle_office_reservation')]
    assert "require_permission('invoices.approve')" in head


def test_an_office_purchase_is_named_as_one_where_it_waits(auth_headers, rworld):
    """The pending list named it by its type alone -- «شراء جديد» -- where the
    owner's name is «شراء كسر من مكتب» (the invoice's own invoice_type_label)."""
    from models import Invoice
    import datetime as dt
    inv = Invoice(invoice_type_id=900000 + int(uuid.uuid4().int % 99999), invoice_type='شراء',
                  # Latest of all: the lists return their newest 50.
                  office_id=rworld['office'].id, date=dt.datetime(2099, 1, 1), total=10.0, status='unpaid',
                  is_posted=False)
    db.session.add(inv)
    db.session.flush()
    for path, key in (('/api/invoices/pending-post', 'invoices'), ('/api/pending-actions', 'pending_invoices')):
        resp = flask_app.test_client().get(path, headers=auth_headers)
        assert resp.status_code == 200, (path, resp.get_data(as_text=True)[:200])
        rows = [r for r in (resp.get_json().get(key) or []) if r['id'] == inv.id]
        assert rows and rows[0]['invoice_type_label'] == 'شراء كسر من مكتب', (path, rows)


def test_the_office_card_counts_its_open_reservations(auth_headers, rworld):
    """What waits to be executed, on the office's card (journey release 2):
    an executed one leaves the count, an undone one comes back."""
    def card():
        resp = flask_app.test_client().get('/api/offices', headers=auth_headers)
        return next(o for o in resp.get_json() if o['id'] == rworld['office'].id)['open_reservations']
    rid = _create(auth_headers, rworld)
    assert card() == {'count': 1, 'grams': GRAMS, 'amount': round(GRAMS * 400.0, 2)}
    assert _settle(auth_headers, rid).status_code == 200
    assert card()['count'] == 0
    assert _unsettle(auth_headers, rid).status_code == 200
    assert card()['count'] == 1
