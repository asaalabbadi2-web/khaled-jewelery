"""The payroll policy is changed as every level-3 setting is (D15, the owner, 26 Nov 2026; ADR-103).

The payroll is reckoned by it -- the salary runs (frozen on each), the end of
service, the advances -- and it is level 3 (services/settings_policy). It was
changed through PUT /payroll/policy by whoever holds employees.payroll, the
manager and the accountant by default, with no reason and without the
financial permission (SETTINGS-FINPERM-001). The laws, the settings' own
(services/financial_settings):
  - a change is refused without system.financial_settings (403
    financial_settings_permission, naming payroll_policy), and without a
    reason (400 reason_required);
  - the policy sent back unchanged is not a change;
  - a change with both is saved, recorded with its reason (ADR-102);
  - reading it stays employees.payroll's.

Run:
    python -m pytest tests/test_payroll_policy_is_financial.py -v
"""
import json
import uuid

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, Settings, SettingsChange, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def row():
    s = Settings.query.order_by(Settings.id).first()
    if s is None:
        s = Settings(main_karat=21)
        db.session.add(s)
    s.payroll_policy = json.dumps({'housing_ratio': 0.25, 'day_divisor': 30})
    db.session.flush()
    return s


def _user(role, overrides=None):
    u = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x',
                permissions=overrides)
    db.session.add(u)
    db.session.flush()
    return u


def _call(method, user, body=None):
    g.pop('current_user', None)
    return getattr(flask_app.test_client(), method)(
        '/api/payroll/policy', headers={'Authorization': f'Bearer {generate_token(user)}'}, json=body)


def _policy(row):
    db.session.expire_all()
    return json.loads(db.session.get(Settings, row.id).payroll_policy)


def test_a_payroll_holder_reads_it_and_sends_it_back_unchanged(row):
    manager = _user('manager')
    read = _call('get', manager)
    assert read.status_code == 200 and read.get_json()['policy']['day_divisor'] == 30
    same = _call('put', manager, {'housing_ratio': 0.25, 'day_divisor': 30})
    assert same.status_code == 200, 'the policy sent back unchanged is not a change'


def test_a_change_without_the_financial_permission_is_refused(row):
    manager = _user('manager')
    refused = _call('put', manager, {'day_divisor': 31, 'reason': 'شهر 31'})
    assert refused.status_code == 403, refused.get_data(as_text=True)[:300]
    assert refused.get_json()['error'] == 'financial_settings_permission'
    assert refused.get_json()['keys'] == ['payroll_policy']
    assert _policy(row)['day_divisor'] == 30


def test_a_change_without_a_reason_is_refused(row):
    holder = _user('manager', {'system.financial_settings': True})
    refused = _call('put', holder, {'day_divisor': 31, 'reason': '  '})
    assert refused.status_code == 400 and refused.get_json()['error'] == 'reason_required'
    assert _policy(row)['day_divisor'] == 30


def test_with_the_permission_and_a_reason_it_is_saved_and_recorded(row):
    holder = _user('manager', {'system.financial_settings': True})
    saved = _call('put', holder, {'day_divisor': 31, 'reason': 'أيام الشهر الفعلية'})
    assert saved.status_code == 200, saved.get_data(as_text=True)[:300]
    assert saved.get_json()['policy']['day_divisor'] == 31
    assert _policy(row)['day_divisor'] == 31
    last = SettingsChange.query.filter_by(key='payroll_policy').order_by(SettingsChange.id.desc()).first()
    assert last is not None and last.reason == 'أيام الشهر الفعلية'
