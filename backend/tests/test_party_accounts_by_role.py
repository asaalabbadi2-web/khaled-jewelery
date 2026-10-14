"""CHART-002 step 4b: a party's accounts are its links; a new one is made under a
mapped parent, and the code builds no parent, no parent twin, and moves nothing.

Until now: the parents were found by number and built when missing (210/2100,
220/2200, the weight roots 71000 and 7210); every voucher re-parented them and
dropped a linked twin whose number broke «7 + number» -- supplier 23 «مكاتب
تسكير فورية واشخاص», linked to 72100021 (19 lines), was refused at every invoice
payment, because the rule's 721000020 is marked abandoned (14 Oct 2026).
"""
import uuid

import pytest

from app import app as flask_app
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, AccountNotMapped
from account_pair_service import link_accounts
from models import Account, AccountingMapping, Office, Supplier, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


def _account(number, name, *, parent=None, weight=False, kind='Liability'):
    account = Account(account_number=number, name=name, type=kind, transaction_type='gold' if weight else 'cash',
                      tracks_weight=weight, parent_id=parent.id if parent else None)
    db.session.add(account)
    db.session.flush()
    return account


def _unmap(role):
    for row in AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                                 account_type=role).all():
        row.is_active = False
    db.session.flush()


def test_a_linked_twin_is_kept_whatever_its_number():
    from party_account_service import ensure_supplier_accounts
    parent = Account.query.filter_by(account_number='2100').one()
    number = f'21{uuid.uuid4().int % 10**6:06d}'
    own = _account(number, f'مكاتب تسكير {_uid()}', parent=parent)
    twin = _account(f'72{uuid.uuid4().int % 10**6:06d}', 'توأمه المربوط', parent=db.session.get(Account, parent.memo_account_id),
                    weight=True)
    link_accounts(own, twin, created_by='test')
    _account(f'7{number}', 'مكرر [غير مستخدم -- مكرَّر، استُبدل]', weight=True)   # the rule's, abandoned
    supplier = Supplier(supplier_code=f'S-{_uid()}', name=own.name, account_id=own.id, account_category_id=parent.id)
    db.session.add(supplier)
    db.session.flush()

    accounts = ensure_supplier_accounts(supplier)

    assert accounts.financial.id == own.id
    assert accounts.memo.id == twin.id


def test_a_new_supplier_with_its_parent_role_unmapped_is_refused_and_nothing_is_made():
    from party_account_service import SUPPLIER_PARENT, ensure_supplier_accounts
    _unmap(SUPPLIER_PARENT)
    supplier = Supplier(supplier_code=f'S-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(supplier)
    db.session.flush()
    before = Account.query.count()
    with pytest.raises(AccountNotMapped):
        ensure_supplier_accounts(supplier)
    assert Account.query.count() == before


def test_a_parent_with_no_twin_refuses_the_twin_and_is_given_none():
    from party_account_service import ensure_customer_accounts
    from models import Customer
    group = _account(f'1{uuid.uuid4().int % 10**6:06d}', f'فئة بلا توأم {_uid()}', kind='Asset')
    customer = Customer(customer_code=f'C-{_uid()}', name=f'عميل {_uid()}', account_category_id=group.id)
    db.session.add(customer)
    db.session.flush()
    with pytest.raises(ValueError, match='بلا حساب وزني مربوط'):
        ensure_customer_accounts(customer)
    assert db.session.get(Account, group.id).memo_account_id is None


def test_an_office_account_is_not_moved_and_a_new_one_is_made_under_the_role():
    from office_account_service import ensure_office_account
    from party_account_service import OFFICE_PARENT, party_parent
    elsewhere = Account.query.filter_by(account_number='210').one()
    own = _account(f'21{uuid.uuid4().int % 10**5:05d}', f'مكتب {_uid()}', parent=elsewhere)
    link_accounts(own, _account(f'7{own.account_number}', 'وزني', weight=True,
                                parent=db.session.get(Account, elsewhere.memo_account_id)), created_by='test')
    office = Office(office_code=f'O-{_uid()}', name=own.name, account_category_id=own.id)
    fresh = Office(office_code=f'O-{_uid()}', name=f'مكتب جديد {_uid()}')
    db.session.add_all([office, fresh])
    db.session.flush()

    assert ensure_office_account(office).parent_id == elsewhere.id
    made = ensure_office_account(fresh)
    assert made.parent_id == party_parent(OFFICE_PARENT).id
    assert db.session.get(Account, made.memo_account_id).parent_id == party_parent(OFFICE_PARENT).memo_account_id
