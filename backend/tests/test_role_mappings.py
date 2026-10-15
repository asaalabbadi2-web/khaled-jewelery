"""MAPPING-UI-1: «الربط المحاسبي» shows every role the code asks for, and a change
to it is checked, kept to the owner and the manager, and recorded.

Measured 15 Oct 2026: the code asked for 69 (operation, role) pairs; the screen
showed 18, from 17 roles written in its own code (6 no longer asked for). The
server took any role name, a weight account for a cash role, the removal of a
required role (refused postings from the next one), and «who» from the request.
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from accounting.role_registry import DEFAULT, ROLES, required_pairs
from models import Account, AccountingMapping, AppUser, AuditLog, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _headers(role):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}, user.username


def _call(method, path, headers, json=None):
    g.pop('current_user', None)
    client = flask_app.test_client()
    return getattr(client, method)(path, headers=headers, json=json)


def _account(*, weight=False, active=True):
    a = Account(account_number=f'98{uuid.uuid4().int % 10**6:06d}', name='حساب اختبار', type='Asset',
                transaction_type='gold' if weight else 'cash', tracks_weight=weight, is_active=active)
    db.session.add(a)
    db.session.flush()
    return a


# ── the registry: every role the code asks for has a name ──

def test_every_required_role_has_its_name_group_and_kind():
    from accounting.role_registry import GROUPS, known
    for operation, key in required_pairs():
        assert key in ROLES and known(operation, key), (operation, key)
        role = ROLES[key]
        assert role.label and role.purpose and role.group in GROUPS and not role.retired, key


def test_the_screen_is_served_every_required_role(auth_headers):
    body = _call('get', '/api/accounting-roles', auth_headers).get_json()
    served = {(o['operation'], r['key']) for r in body['roles'] for o in r['operations'] if o['required']}
    assert served == required_pairs()
    assert body['summary']['required'] == len(required_pairs())


def _default_cash():
    """A default cash row, as production has (the test chart maps each operation's own)."""
    row = AccountingMapping.query.filter_by(operation_type=DEFAULT, account_type='cash').first()
    if row is None:
        row = AccountingMapping(operation_type=DEFAULT, account_type='cash', account_id=_account().id,
                                is_active=True, created_by='t')
        db.session.add(row)
        db.session.flush()
    return row


def test_an_operation_without_its_own_row_shows_the_default_it_inherits(auth_headers):
    default_row = _default_cash()
    own = AccountingMapping.query.filter_by(operation_type='بيع', account_type='cash').first()
    if own is not None:
        db.session.delete(own)
        db.session.flush()
    body = _call('get', '/api/accounting-roles', auth_headers).get_json()
    cash = next(r for r in body['roles'] if r['key'] == 'cash')
    sale = next(o for o in cash['operations'] if o['operation'] == 'بيع')
    assert sale['mapping_id'] is None and sale['source'] == 'default'
    assert sale['account']['id'] == default_row.account_id


def _answered_by_its_alias():
    """(بيع, sales_gold_new) with no row of its own: production's case -- revenue answers it."""
    for op in ('بيع', DEFAULT):
        own = AccountingMapping.query.filter_by(operation_type=op, account_type='sales_gold_new').first()
        if own is not None:
            db.session.delete(own)
    revenue = AccountingMapping.query.filter_by(operation_type='بيع', account_type='revenue').first()
    if revenue is None:
        revenue = AccountingMapping(operation_type='بيع', account_type='revenue', account_id=_account().id,
                                    is_active=True, created_by='t')
        db.session.add(revenue)
    db.session.flush()
    return revenue


def test_a_role_its_alias_answers_is_mapped_and_says_by_what(auth_headers):
    # Measured on the production copy (15 Oct 2026): the screen called it unmapped,
    # while every sale posted it on «revenue» (accounting.mappings.ROLE_ALIASES).
    revenue = _answered_by_its_alias()
    body = _call('get', '/api/accounting-roles', auth_headers).get_json()
    role = next(r for r in body['roles'] if r['key'] == 'sales_gold_new')
    sale = next(o for o in role['operations'] if o['operation'] == 'بيع')
    assert sale['source'] == 'alias' and sale['via']['role'] == 'revenue'
    assert sale['account']['id'] == revenue.account_id


def test_the_row_an_alias_leans_on_is_not_removed(auth_headers):
    revenue = _answered_by_its_alias()
    resp = _call('delete', f'/api/accounting-mappings/{revenue.id}', auth_headers)
    assert resp.status_code == 400 and 'مبيعات ذهب جديد' in resp.get_json()['message']


def test_an_override_not_set_is_offered_not_shown(auth_headers):
    body = _call('get', '/api/accounting-roles', auth_headers).get_json()
    customers = next(r for r in body['roles'] if r['key'] == 'customers')
    shown = {o['operation'] for o in customers['operations']}
    assert 'سندات' in shown | set(customers['overridable'])
    assert not shown & set(customers['overridable'])


# ── saving is checked ──

def test_an_unknown_role_a_retired_role_a_wrong_kind_and_an_inactive_account_are_refused(auth_headers):
    # Each case's account is made just before its call: a refusal rolls the session back.
    for key, make, code in (
            ('gold_inventry_new', _account, 'UNKNOWN_ROLE'),
            ('inventory_21k', lambda: _account(weight=True), 'RETIRED_ROLE'),
            ('gold_inventory_new', lambda: _account(weight=True), 'WRONG_KIND'),
            ('gold_cost_of_sales_weight', _account, 'WRONG_KIND'),
            ('gold_inventory_new', lambda: _account(active=False), 'INACTIVE_ACCOUNT')):
        payload = {'operation_type': DEFAULT, 'account_type': key, 'account_id': make().id}
        resp = _call('post', '/api/accounting-mappings', auth_headers, payload)
        assert resp.status_code == 400 and resp.get_json()['error'] == code, (payload, resp.get_json())


def test_a_change_is_recorded_with_the_sessions_user():
    headers, name = _headers('manager')
    account = _account()
    resp = _call('post', '/api/accounting-mappings', headers,
                 {'operation_type': DEFAULT, 'account_type': 'gold_cost_of_sales', 'account_id': account.id,
                  'created_by': 'someone else'})
    assert resp.status_code == 200, resp.get_json()
    row = AccountingMapping.query.filter_by(operation_type=DEFAULT, account_type='gold_cost_of_sales').one()
    assert row.account_id == account.id
    entry = AuditLog.query.filter_by(action='accounting_mapping_saved', entity_id=row.id).order_by(
        AuditLog.id.desc()).first()
    assert entry.user_name == name and account.account_number in entry.details


def test_a_batch_is_saved_whole_or_not_at_all(auth_headers):
    good, bad = _account(), _account(weight=True)
    before = AccountingMapping.query.filter_by(operation_type=DEFAULT, account_type='karat_diff_revenue').one()
    resp = _call('post', '/api/accounting-mappings/batch', auth_headers, {'mappings': [
        {'operation_type': DEFAULT, 'account_type': 'karat_diff_revenue', 'account_id': good.id},
        {'operation_type': DEFAULT, 'account_type': 'karat_diff_expense', 'account_id': bad.id}]})
    assert resp.status_code == 400
    db.session.expire_all()
    assert AccountingMapping.query.filter_by(operation_type=DEFAULT, account_type='karat_diff_revenue').one() \
        .account_id == before.account_id


# ── removing ──

def test_a_required_role_is_not_left_without_its_account(auth_headers):
    # The sale's own cash row, with no default to fall back on.
    default = AccountingMapping.query.filter_by(operation_type=DEFAULT, account_type='cash').first()
    if default is not None:
        db.session.delete(default)
    row = AccountingMapping.query.filter_by(operation_type='بيع', account_type='cash').first()
    if row is None:
        row = AccountingMapping(operation_type='بيع', account_type='cash', account_id=_account().id,
                                is_active=True, created_by='t')
        db.session.add(row)
    db.session.flush()
    resp = _call('delete', f'/api/accounting-mappings/{row.id}', auth_headers)
    assert resp.status_code == 400 and resp.get_json()['error'] == 'REQUIRED_ROLE'
    assert db.session.get(AccountingMapping, row.id) is not None


def test_a_live_roles_default_is_changed_not_removed(auth_headers):
    # vat_settlement is optional, and its account is created again when it is not mapped.
    row = AccountingMapping(operation_type=DEFAULT, account_type='vat_settlement', account_id=_account().id,
                            is_active=True, created_by='t')
    db.session.add(row)
    db.session.flush()
    resp = _call('delete', f'/api/accounting-mappings/{row.id}', auth_headers)
    assert resp.status_code == 400 and resp.get_json()['error'] == 'DEFAULT_ROW'


def test_a_retired_roles_row_is_removed(auth_headers):
    row = AccountingMapping(operation_type=DEFAULT, account_type='inventory_21k',
                            account_id=_account(weight=True).id, is_active=True, created_by='t')
    db.session.add(row)
    db.session.flush()
    assert _call('delete', f'/api/accounting-mappings/{row.id}', auth_headers).status_code == 200


def test_an_operations_override_is_removed_when_the_default_still_serves_it(auth_headers):
    _default_cash()
    override = AccountingMapping.query.filter_by(operation_type='بيع', account_type='cash').first()
    assert _call('delete', f'/api/accounting-mappings/{override.id}', auth_headers).status_code == 200


# ── who may change it ──

def test_the_accountant_sees_the_mapping_and_does_not_change_it():
    headers, _ = _headers('accountant')
    assert _call('get', '/api/accounting-roles', headers).status_code == 200
    resp = _call('post', '/api/accounting-mappings', headers,
                 {'operation_type': DEFAULT, 'account_type': 'gold_cost_of_sales', 'account_id': _account().id})
    assert resp.status_code == 403
