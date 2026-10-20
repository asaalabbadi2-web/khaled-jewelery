"""An office is stopped only when nothing stands between us (the owner, 20 Oct 2026).

«تعطيل» on the offices list was one tap with no question -- and was allowed for
an office holding 405.6 g of our gold, owed 14,078.80 and with two reservations
open (مكتب الراقي on the 17 Oct copy). The office stopped, the gold and the
debt stayed, out of the list's sight.

The law: an office is refused stopping, `office_not_settled`, while its
deposit holds gold, its supplier account a balance in riyals or gold, or a
reservation of it waits to be executed; the refusal says which. A settled one
stops; a stopped one starts again as before.

Run:
    python -m pytest tests/test_an_office_is_stopped_only_when_settled.py -v
"""
import datetime as dt
import uuid

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, Office, OfficeReservation, Supplier, db
from services.office_deposits import ensure_deposit
from tests.office_deposit import map_deposit_parent


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


def _account(prefix, name, kind, *, weight):
    a = Account(account_number=f'{prefix}{uuid.uuid4().int % 10**6:06d}', name=name, type=kind,
                transaction_type='gold' if weight else 'cash', tracks_weight=weight)
    db.session.add(a)
    db.session.flush()
    return a


def _post(account, **amounts):
    je = JournalEntry(entry_number=f'JE-OS-{_uid()}', date=dt.datetime(2026, 10, 1), description='t',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='t', **amounts))
    db.session.flush()


@pytest.fixture
def office():
    """A settled office: its supplier on its own accounts, its deposit made, nothing between us."""
    map_deposit_parent()
    cash = _account('21', f'مكتب {_uid()}', 'Liability', weight=False)
    gold = _account('721', f'وزني مكتب {_uid()}', 'Liability', weight=True)
    cash.memo_account_id, gold.memo_account_id = gold.id, cash.id
    supplier = Supplier(supplier_code=f'SOS-{_uid()}', name=f'مكتب {_uid()}', account_id=cash.id)
    db.session.add(supplier)
    db.session.flush()
    o = Office(office_code=f'OOS-{_uid()}', name=f'مكتب {_uid()}', active=True,
               account_category_id=cash.id, supplier_id=supplier.id)
    db.session.add(o)
    db.session.flush()
    safe, _ = ensure_deposit(o, by='t')
    return {'office': o, 'cash': cash, 'gold': gold, 'deposit': db.session.get(Account, safe.account_id)}


def _stop(headers, office):
    return flask_app.test_client().delete(f"/api/offices/{office.id}", headers=headers)


def _active(office):
    db.session.expire_all()
    return db.session.get(Office, office.id).active


def test_a_settled_office_stops_and_starts_again(auth_headers, office):
    assert _stop(auth_headers, office['office']).status_code == 200
    assert _active(office['office']) is False
    resp = flask_app.test_client().post(f"/api/offices/{office['office'].id}/activate", headers=auth_headers)
    assert resp.status_code == 200
    assert _active(office['office']) is True


@pytest.mark.parametrize('between, reason', [
    ('deposit', 'deposit'),
    ('owed', 'cash'),
    ('gold', 'gold'),
    ('reservation', 'open_reservations'),
])
def test_an_office_with_something_between_us_is_not_stopped(auth_headers, office, between, reason):
    if between == 'deposit':
        _post(office['deposit'], debit_21k=405.6)
    elif between == 'owed':
        _post(office['cash'], cash_credit=14078.80)
    elif between == 'gold':
        _post(office['gold'], credit_24k=2.0)
    else:
        db.session.add(OfficeReservation(office_id=office['office'].id, reservation_code=f'RES-{_uid()}',
                                         weight_grams=10, weight_main_karat=10, price_per_gram=400,
                                         execution_price_per_gram=400, total_amount=4000, status='approved'))
        db.session.flush()
    resp = _stop(auth_headers, office['office'])
    assert resp.status_code == 409, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'office_not_settled'
    assert reason in body['reasons']
    assert _active(office['office']) is True
