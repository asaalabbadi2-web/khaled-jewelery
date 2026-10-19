"""An office's gold is a deposit, as money in a bank (ADR-052).

The owner (18 Oct 2026, «نموذج البنك»): the gold kept with an office is ours,
held for us -- bought from it by a reservation, or sent to it -- and pays
suppliers. It sat on the office's supplier weight account, a liability: our
gold read as the office's debt, and a transfer from it could not tell taking
our deposit back from buying from it (AV-2026-00012).

The laws:
  - the tool makes each office a deposit -- a weight-only asset under the
    mapped «ذهب مودع لدى المكاتب», its safe at the place «deposit» -- makes it
    the office's gold safe, stops the old one, and moves what is ours there
    in one entry; what the office is owed, and grams under DUST, stay; a
    second run writes nothing;
  - a deposit is the shop's stock: a transfer to and from it is allowed;
  - a count of all locations leaves a deposit out (no one counts it on the
    floor: zeroed, the year's opening count would write it off); a count of
    the deposit alone is allowed;
  - the scrap/new report reads a deposit as scrap -- raw gold;
  - the safes screen groups gold by its kind.

Run:
    python -m pytest tests/test_office_gold_deposits.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import (
    Account, AccountingMapping, JournalEntry, JournalEntryLine, Office, SafeBox, Supplier, db,
)
from services.repair.office_gold_deposits import DEPOSIT_PARENT, REFERENCE, make_deposits
from tests.office_deposit import map_deposit_parent

NOW = dt.datetime(2026, 10, 19, 10, 0)


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


def _account(prefix, name, kind, *, weight, parent=None):
    a = Account(account_number=f'{prefix}{uuid.uuid4().int % 10**6:06d}', name=name, type=kind,
                transaction_type='gold' if weight else 'cash', tracks_weight=weight,
                parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _post(account, **karats):
    je = JournalEntry(entry_number=f'JE-OD-{_uid()}', date=dt.datetime(2026, 10, 1), description='ذهب',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='ذهب', **karats))
    db.session.flush()


@pytest.fixture
def parent():
    """The role mapped, as the tool leaves it on production (71330)."""
    return map_deposit_parent()


@pytest.fixture
def office(parent):
    """An office as on the 17 Oct copy: its gold safe on its supplier weight account."""
    cash = _account('21', f'مكتب {_uid()}', 'Liability', weight=False)
    gold = _account('721', f'موردو ذهب مشغول وزني - مكتب {_uid()}', 'Liability', weight=True)
    cash.memo_account_id, gold.memo_account_id = gold.id, cash.id
    old = SafeBox(name=f'خزنة مكتب {_uid()}', safe_type='gold', account_id=gold.id, is_active=True)
    db.session.add(old)
    db.session.flush()
    supplier = Supplier(supplier_code=f'SOD-{_uid()}', name=f'مكتب {_uid()}', default_safe_box_id=old.id,
                        account_id=cash.id)      # its cash account, as on production (2100017)
    db.session.add(supplier)
    db.session.flush()
    o = Office(office_code=f'OOD-{_uid()}', name=f'مكتب  الوديعة {_uid()}', active=True,
               account_category_id=cash.id, supplier_id=supplier.id)
    db.session.add(o)
    db.session.flush()
    _post(gold, debit_21k=396.6)        # ours there
    _post(gold, credit_24k=2.0)         # owed to it
    _post(gold, debit_18k=0.01)         # dust
    return {'office': o, 'supplier': supplier, 'gold': gold, 'old': old, 'parent': parent}


def _net(account, k):
    from services.live_balances import live_balances_by_account_ids
    return round(float((live_balances_by_account_ids([account.id]).get(account.id) or {}).get(f'{k}k') or 0), 3)


def _plan(result, office):
    return next(p for p in result['offices'] if p['office'] == office.name)


def test_the_tool_makes_a_deposit_and_moves_our_gold_there(office):
    plan = _plan(make_deposits(by='owner', now=NOW), office['office'])
    db.session.expire_all()
    supplier = db.session.get(Supplier, office['supplier'].id)
    deposit = supplier.default_safe_box

    assert deposit.stock_location == 'deposit' and deposit.group == 'gold_deposit'
    assert deposit.account.parent_id == office['parent'].id and deposit.account.tracks_weight
    assert deposit.account.type == 'Asset'
    assert ' '.join(office['office'].name.split()) in deposit.name and deposit.name.startswith('ذهب مودع لدى')
    assert db.session.get(SafeBox, office['old'].id).is_active is False

    assert _net(deposit.account, 21) == 396.6
    assert (_net(office['gold'], 21), _net(office['gold'], 24), _net(office['gold'], 18)) == (0.0, -2.0, 0.01), \
        'what the office is owed, and dust, stay on its supplier account'
    entry = JournalEntry.query.filter_by(reference_type=REFERENCE, reference_id=office['office'].id).one()
    assert entry.date == NOW and plan['entry'] == entry.entry_number


def test_a_second_run_writes_nothing(office):
    make_deposits(by='owner', now=NOW)
    accounts, entries = Account.query.count(), JournalEntry.query.count()
    plan = _plan(make_deposits(by='owner', now=NOW), office['office'])
    assert (Account.query.count(), JournalEntry.query.count()) == (accounts, entries)
    assert 'entry' not in plan and 'made' not in plan


def test_the_parent_is_made_and_mapped_when_missing():
    from accounting.mappings import get_account_id_for_mapping, require_account
    AccountingMapping.query.filter_by(account_type=DEPOSIT_PARENT).delete()
    db.session.flush()
    try:
        root = db.session.get(Account, require_account('افتراضي', 'gold_inventory_root'))
    except Exception:
        pytest.skip('the test database maps no gold inventory root')
    result = make_deposits(by='owner', now=NOW)
    weight = db.session.get(Account, get_account_id_for_mapping('افتراضي', DEPOSIT_PARENT))
    assert result['parent_made'] and weight.tracks_weight and weight.name == 'ذهب مودع لدى المكاتب وزني'
    group = db.session.get(Account, weight.memo_account_id)
    assert group.parent_id == root.id and group.name == 'ذهب مودع لدى المكاتب'


def test_a_deposit_transfers_as_a_bank_does(auth_headers, office):
    make_deposits(by='owner', now=NOW)
    db.session.expire_all()
    deposit = db.session.get(Supplier, office['supplier'].id).default_safe_box
    acc = _account('7130', 'معروض', 'Asset', weight=True)
    showroom = SafeBox(name=f'معروض {_uid()}', safe_type='gold', account_id=acc.id, is_active=True,
                       stock_location='showroom')
    db.session.add(showroom)
    db.session.flush()
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/safe-boxes/transfer-voucher', headers=auth_headers, json={
        'from_safe_box_id': deposit.id, 'to_safe_box_id': showroom.id, 'weights': {'21k': 100.0}})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


def test_a_count_of_all_leaves_a_deposit_out(office):
    from models import InventoryCountSession
    from services.inventory_count_service import InventoryCountService
    make_deposits(by='owner', now=NOW)
    db.session.expire_all()
    deposit = db.session.get(Supplier, office['supplier'].id).default_safe_box
    everything = InventoryCountSession(status='open', session_type='periodic', opened_by='t', opened_at=NOW)
    alone = InventoryCountSession(status='open', session_type='periodic', opened_by='t', opened_at=NOW,
                                  safe_box_id=deposit.id)
    assert deposit.id not in InventoryCountService._scope(everything)
    assert InventoryCountService._scope(alone) == {deposit.id}


def test_the_report_reads_a_deposit_as_scrap():
    from models import SCRAP_LOCATIONS, STOCK_LOCATIONS
    from services.stock_ledger import _location_filter
    assert 'deposit' in STOCK_LOCATIONS and 'deposit' in SCRAP_LOCATIONS
    assert 'deposit' in str(_location_filter('scrap').compile(compile_kwargs={'literal_binds': True}))


@pytest.mark.parametrize('location, group', [
    ('showroom', 'gold_shop'), ('scrap', 'gold_shop'), ('workshop', 'gold_shop'), ('transit', 'gold_shop'),
    ('custody', 'gold_custody'), ('deposit', 'gold_deposit'), (None, 'party_gold')])
def test_the_safes_screen_groups_gold_by_its_kind(location, group):
    assert SafeBox(safe_type='gold', stock_location=location).group == group
    assert SafeBox(safe_type='cash').group == 'cash'


def test_a_deposit_shows_what_is_owed_to_its_office(auth_headers, office):
    """Option A (the owner, 19 Oct 2026): the gold is ours at execution -- usable
    -- and the office's riyals are shown beside it, as a bank shows a loan."""
    make_deposits(by='owner', now=NOW)
    db.session.expire_all()
    supplier = db.session.get(Supplier, office['supplier'].id)
    cash = db.session.get(Account, office['office'].account_category_id)
    je = JournalEntry(entry_number=f'JE-OD-{_uid()}', date=dt.datetime(2026, 10, 2), description='ثمن حجز',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=cash.id, supplier_id=supplier.id,
                                    description='ثمن مستحق للمكتب', cash_credit=4000.0))
    db.session.flush()
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/safe-boxes/balances', headers=auth_headers)
    assert resp.status_code == 200
    row = next(r for r in resp.get_json()['rows'] if r['id'] == supplier.default_safe_box_id)
    assert row['office_cash'] == -4000.0
    assert all('office_cash' not in r for r in resp.get_json()['rows'] if r.get('stock_location') != 'deposit')
