"""A financial setting is changed only by who holds system.financial_settings, granted by the system admin alone (ADR-103).

The owner, 26 Nov 2026 (D13): «system.financial_settings»; «لا يمنح
system.financial_settings إلا مسؤول النظام»، في الخادم داخل
PUT /users/<id>/permissions؛ لا يمنحها أحد لنفسه؛ كل منح أو سحب يُسجَّل؛
لا تُمنح لأي حساب عند النشر. The laws:
  - a level-3 setting (services/settings_policy.LEVEL_3) is not changed
    through PUT or PATCH /settings, the weight-closing settings or a VAT
    period by a user without the permission -- a value sent unchanged is not
    a change;
  - the permission is in the catalog, held by no role: the system admin alone
    holds it, by the code, until the owner grants it to a named account;
  - only the system admin grants or withdraws it, and not to themselves;
  - every change of a user's role or permissions is recorded, append-only.

Run:
    python -m pytest tests/test_financial_settings_permission.py -v
"""
import json
import uuid

import pytest
from flask import g
from sqlalchemy import text

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, PermissionChange, Settings, db
from permissions import ALL_PERMISSIONS, ROLE_PERMISSIONS, effective_permissions

CODE = 'system.financial_settings'


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, vat_mapped):
    yield


def _user(role, overrides=None):
    u = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x',
                permissions=overrides)
    db.session.add(u)
    db.session.flush()
    return u


def _headers(user):
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _call(method, path, user, body=None):
    g.pop('current_user', None)
    return getattr(flask_app.test_client(), method)(path, headers=_headers(user), json=body)


@pytest.fixture
def row():
    s = Settings.query.order_by(Settings.id).first()
    if s is None:
        s = Settings(main_karat=21)
        db.session.add(s)
        db.session.flush()
    return s


def _versions(user, *keys):
    resp = _call('get', '/api/settings/versions', user)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return {k: resp.get_json()['versions'].get(k, 0) for k in keys}


def test_the_permission_is_in_the_catalog_and_no_role_holds_it():
    assert CODE in ALL_PERMISSIONS
    assert all(CODE not in grants for role, grants in ROLE_PERMISSIONS.items() if role != 'system_admin')
    assert CODE in effective_permissions('system_admin', None), 'the system admin holds every code, by the code'
    assert CODE not in effective_permissions('manager', {'system.settings': True})


def test_a_level_3_change_without_the_permission_is_refused(row):
    clerk = _user('manager', {'system.settings': True})
    seen = _versions(clerk, 'office_custom_fees_usd', 'company_phone')
    refused = _call('patch', '/api/settings', clerk,
                    {'changes': {'office_custom_fees_usd': 47}, 'versions': seen, 'reason': 'رسوم'})
    assert refused.status_code == 403, refused.get_data(as_text=True)[:300]
    assert refused.get_json()['error'] == 'financial_settings_permission'
    assert refused.get_json()['keys'] == ['office_custom_fees_usd']
    ok = _call('patch', '/api/settings', clerk,
               {'changes': {'company_phone': '0522222222'}, 'versions': {'company_phone': seen['company_phone']}})
    assert ok.status_code == 200, 'a level-1 setting stays theirs'
    put = _call('put', '/api/settings', clerk, {'office_custom_fees_usd': 47})
    assert put.status_code == 403 and put.get_json()['error'] == 'financial_settings_permission'
    db.session.expire_all()
    assert float(Settings.query.get(row.id).office_custom_fees_usd or 0) != 47


def test_the_old_screens_full_save_of_unchanged_values_is_not_a_financial_change(row):
    clerk = _user('manager', {'system.settings': True})
    body = {k: getattr(row, k) for k in ('tax_rate', 'office_custom_fees_usd', 'voucher_auto_post', 'main_karat')}
    body['company_phone'] = '0533333333'
    resp = _call('put', '/api/settings', clerk, body)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]


def test_with_the_permission_and_a_reason_it_is_changed(row):
    holder = _user('manager', {'system.settings': True, CODE: True})
    seen = _versions(holder, 'office_custom_fees_usd')
    resp = _call('patch', '/api/settings', holder,
                 {'changes': {'office_custom_fees_usd': 48}, 'versions': seen, 'reason': 'رسوم المكتب'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]


def test_the_weight_closing_settings_and_a_vat_period_ask_it_too(row):
    clerk = _user('manager', {'system.settings': True})
    wc = _call('put', '/api/weight-closing/settings', clerk, {'enabled': False})
    assert wc.status_code == 403 and wc.get_json()['error'] == 'financial_settings_permission'
    vat = _call('post', '/api/settings/vat-periods', clerk,
                {'effective_from': '2099-01-01', 'input_vat_recoverable': True, 'sales_vat_charged': True})
    assert vat.status_code == 403 and vat.get_json()['error'] == 'financial_settings_permission'


def test_only_the_system_admin_grants_it(row):
    granter = _user('manager', {'users.change_permissions': True})
    target = _user('accountant')
    refused = _call('put', f'/api/users/{target.id}/permissions', granter, {'permissions': {CODE: True}})
    assert refused.status_code == 403, refused.get_data(as_text=True)[:300]
    assert refused.get_json()['error'] == 'financial_grant_admin_only'
    other = _call('put', f'/api/users/{target.id}/permissions', granter, {'permissions': {'audit.view': True}})
    assert other.status_code == 200, 'any other grant stays theirs'
    admin = _user('system_admin')
    granted = _call('put', f'/api/users/{target.id}/permissions', admin,
                    {'permissions': {'audit.view': True, CODE: True}})
    assert granted.status_code == 200, granted.get_data(as_text=True)[:300]
    db.session.expire_all()
    assert CODE in effective_permissions(target.role, AppUser.query.get(target.id).permissions)
    # Withdrawn by the system admin alone too.
    kept = dict(AppUser.query.get(target.id).permissions)
    refused = _call('put', f'/api/users/{target.id}/permissions', granter,
                    {'permissions': {**kept, CODE: False}})
    assert refused.status_code == 403 and refused.get_json()['error'] == 'financial_grant_admin_only'


def test_no_one_grants_it_to_themselves():
    admin = _user('system_admin')
    resp = _call('put', f'/api/users/{admin.id}/permissions', admin, {'permissions': {CODE: True}})
    assert resp.status_code == 403 and resp.get_json()['error'] == 'financial_grant_to_self'


def test_every_grant_and_role_change_is_recorded_append_only():
    admin = _user('system_admin')
    target = _user('employee')
    resp = _call('put', f'/api/users/{target.id}/permissions', admin,
                 {'role': 'accountant', 'permissions': {CODE: True}})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    rows = PermissionChange.query.filter_by(target_user_id=target.id).order_by(PermissionChange.id).all()
    assert {(r.kind, r.key, json.loads(r.old_value), json.loads(r.new_value)) for r in rows} == {
        ('role', 'role', 'employee', 'accountant'), ('permission', CODE, None, True)}
    assert all(r.actor == admin.username for r in rows)
    with pytest.raises(Exception) as delete:
        with db.session.begin_nested():
            db.session.execute(text('DELETE FROM permission_change WHERE id = :id'), {'id': rows[0].id})
    assert 'permission_change' in str(delete.value)
