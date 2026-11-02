"""An employee's file, in one place, each part from its owner (EMP-2).

The owner, 1 Nov 2026 («اودع ثم انتقل»). What the system knew of an employee
lay on six screens and some of it on none. The file reads each part from the
service that owns it -- nothing reckoned again -- and says what is missing.

Run:
    python -m pytest tests/test_employee_file.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app

POLICY = {'housing_ratio': 0.25, 'transport_ratio': 0.10, 'advance_cap_ratio': 0.10,
          'advance_installments': 3, 'attendance_enabled': False, 'day_divisor': 30,
          'overtime_premium_ratio': 0.5}


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def test_the_file_says_what_is_missing_and_fills_as_the_parts_are_entered(auth_headers):
    assert _call('put', '/api/payroll/policy', auth_headers, POLICY)[0] == 200
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف ملف {uuid.uuid4().hex[:6]}', 'is_active': True})
    emp = body['id']
    code, file = _call('get', f'/api/employees/{emp}/file', auth_headers)
    assert code == 200, file
    assert {'الهوية الوطنية / الإقامة', 'تاريخ التعيين', 'هيكل الراتب', 'طريقة الصرف'} <= set(file['missing'])
    keys = {item['key'] for item in file['missing_items']}
    assert {'national_id', 'hire_date', 'structure', 'payment_method'} <= keys, 'each by its key (HR-UX ط6)'
    assert [item['label'] for item in file['missing_items']] == file['missing']
    assert file['salary_owed'] == 0.0
    _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
          {'effective_from': '2026-01-01', 'basic': 6000, 'housing': 1500, 'transport': 600})
    _call('put', f'/api/employees/{emp}', auth_headers,
          {'national_id': '1000000001', 'hire_date': '2025-01-01', 'job_title': 'بائع', 'phone': '0500000000',
           'payment_method': 'bank'})
    file = _call('get', f'/api/employees/{emp}/file', auth_headers)[1]
    assert file['missing'] == ['الآيبان'], 'paid by bank, his IBAN is wanted'
    assert file['salary']['structure']['gross'] == 8100.0
    roles = {a['role'] for a in file['accounts']}
    assert 'personal' in roles and 'salary_payable' in roles, 'each of his accounts, from the books'
    assert file['custody'] == {} and file['bonuses']['approved_unpaid'] == 0.0


def test_the_file_says_how_complete_it_is(auth_headers):
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف اكتمال {uuid.uuid4().hex[:6]}', 'is_active': True, 'phone': '0500000000',
                        'job_title': 'بائع'})
    file = _call('get', f"/api/employees/{body['id']}/file", auth_headers)[1]
    assert file['completeness'] == {'done': 2, 'of': 6}, 'the phone and the title of six'
    _call('put', f"/api/employees/{body['id']}", auth_headers, {'payment_method': 'bank'})
    file = _call('get', f"/api/employees/{body['id']}/file", auth_headers)[1]
    assert file['completeness'] == {'done': 3, 'of': 7}, 'paid by bank, his IBAN is asked too'
