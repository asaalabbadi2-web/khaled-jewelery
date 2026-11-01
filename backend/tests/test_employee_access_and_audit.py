"""An employee stopped is a user stopped; every change to his file is recorded (EMP-1).

The owner, 1 Nov 2026: «أوقف دخول الموظفَين الموقوفَين فورًا؟ نعم» and, of his
custody, «يُسمح مع تنبيه». On the 1 Nov copy the users of the two stopped
employees were active and signed in -- login read the user alone, stopping an
employee set his own flag -- and the audit log held no row for any employee.

  1. stopping him (toggle, edit, a delete that stops) stops his users and
     revokes their sessions; starting him again leaves them stopped;
  2. login refuses a user whose employee is stopped;
  3. his open custody is said, the stop not refused;
  4. each change is recorded, field by field;
  5. his salary and his leaving date are not written by his file's edit
     (HR-UX ط1, 2 Nov 2026): the structure's and the settlement's;
  - the tool: the users of employees stopped before, and custody links to
    deleted safes.

Run:
    python -m pytest tests/test_employee_access_and_audit.py -v
"""
import json
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import AppUser, AuditLog, Employee, RefreshToken, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def _employee(headers, **fields):
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'موظف دخول {uuid.uuid4().hex[:6]}', 'is_active': True, **fields})
    assert code in (200, 201), body
    return body['id']


def _user(employee_id):
    user = AppUser(username=f'emp-{uuid.uuid4().hex[:6]}', role='employee', is_active=True,
                   employee_id=employee_id)
    user.set_password('pass-1234')
    db.session.add(user)
    db.session.flush()
    db.session.add(RefreshToken(token_hash=uuid.uuid4().hex, user_id=user.id, user_type='app_user',
                                expires_at=datetime(2099, 1, 1)))
    db.session.commit()
    return user


def _audit(employee_id, action):
    return AuditLog.query.filter_by(entity_type='Employee', entity_id=employee_id, action=action).all()


def test_stopping_him_stops_his_users_and_revokes_their_sessions(auth_headers):
    emp = _employee(auth_headers)
    user = _user(emp)
    code, body = _call('post', f'/api/employees/{emp}/toggle-active', auth_headers)
    assert code == 200 and body['is_active'] is False and body['users_closed'] == [user.username], body
    db.session.expire_all()
    assert db.session.get(AppUser, user.id).is_active is False
    assert RefreshToken.query.filter_by(user_id=user.id, is_revoked=False).count() == 0
    code, body = _call('post', f'/api/employees/{emp}/toggle-active', auth_headers)
    assert body['is_active'] is True
    assert db.session.get(AppUser, user.id).is_active is False, 'a user is started on its own'


def test_an_edit_or_a_delete_that_stops_him_stops_his_users_too(auth_headers):
    one, two = _employee(auth_headers), _employee(auth_headers)
    first, second = _user(one), _user(two)
    assert _call('put', f'/api/employees/{one}', auth_headers, {'is_active': False})[0] == 200
    code, body = _call('delete', f'/api/employees/{two}', auth_headers)
    assert code == 200 and body['deactivated'] is True, 'his user keeps him: stopped, not deleted'
    db.session.expire_all()
    assert (db.session.get(AppUser, first.id).is_active, db.session.get(AppUser, second.id).is_active) == \
        (False, False)


def test_login_refuses_a_user_whose_employee_is_stopped(auth_headers):
    emp = _employee(auth_headers)
    user = _user(emp)
    db.session.get(Employee, emp).is_active = False          # stopped before the law, his user left on
    db.session.commit()
    resp = flask_app.test_client().post('/api/auth/login', json={'username': user.username, 'password': 'pass-1234'})
    assert resp.status_code == 403 and resp.get_json()['error'] == 'employee_inactive'


def test_his_open_custody_is_said_and_the_stop_not_refused(auth_headers):
    from services.employee_access import custody_warning
    warning = custody_warning({'gold': {'safe': 'عهدة ذهب مسعد', 'balances': {'21k': 11.8}}})
    assert '11.800 جم عيار 21' in warning
    emp = _employee(auth_headers)
    code, body = _call('post', f'/api/employees/{emp}/toggle-active', auth_headers)
    assert code == 200 and 'custody_open' in body and body['warning'] is None, 'no custody, no warning'


def test_each_change_of_his_file_is_recorded(auth_headers):
    emp = _employee(auth_headers, job_title='بائع')
    assert len(_audit(emp, 'create_employee')) == 1
    _call('put', f'/api/employees/{emp}', auth_headers, {'job_title': 'مشرف', 'phone': '0500000000'})
    changes = json.loads(_audit(emp, 'update_employee')[0].details)['changes']
    assert changes['job_title'] == {'before': 'بائع', 'after': 'مشرف'} and 'phone' in changes
    assert 'photo' not in changes
    _call('put', f'/api/employees/{emp}', auth_headers, {'job_title': 'مشرف'})
    assert len(_audit(emp, 'update_employee')) == 1, 'nothing changed, nothing recorded'
    _call('post', f'/api/employees/{emp}/toggle-active', auth_headers)
    assert len(_audit(emp, 'stop_employee')) == 1


def test_his_salary_and_his_leaving_date_are_not_written_by_his_file_s_edit(auth_headers):
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف راتب {uuid.uuid4().hex[:6]}', 'salary': 7000.0})
    assert (code, body.get('code')) == (400, 'salary_is_the_structure'), body
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف ترك {uuid.uuid4().hex[:6]}', 'termination_date': '2041-01-31'})
    assert (code, body.get('code')) == (400, 'termination_is_the_settlement'), body
    emp = _employee(auth_headers)
    code, body = _call('put', f'/api/employees/{emp}', auth_headers, {'salary': 9000.0, 'job_title': 'مشرف'})
    assert (code, body.get('code')) == (400, 'salary_is_the_structure'), body
    assert db.session.get(Employee, emp).job_title != 'مشرف', 'refused whole'
    code, body = _call('put', f'/api/employees/{emp}', auth_headers, {'termination_date': '2041-01-31'})
    assert (code, body.get('code')) == (400, 'termination_is_the_settlement'), body
    code, body = _call('put', f'/api/employees/{emp}', auth_headers,
                       {'salary': 0.0, 'termination_date': None, 'job_title': 'مشرف'})
    assert code == 200 and body['job_title'] == 'مشرف', 'what it holds, sent back, is no change'


def test_the_tool_stops_the_users_of_those_stopped_before_and_clears_dead_links(auth_headers):
    from services.repair.employee_access_cleanup import cleanup
    emp = _employee(auth_headers)
    user = _user(emp)
    # production holds no foreign key on it (the migration adds one, NOT VALID): as there
    db.session.execute(db.text('ALTER TABLE employee DROP CONSTRAINT IF EXISTS employee_cash_safe_box_id_fkey'))
    employee = db.session.get(Employee, emp)
    employee.is_active, employee.cash_safe_box_id = False, 999999      # as abr; as صالح's safe 40
    db.session.commit()
    plan = cleanup(by='t', now=datetime(2026, 11, 1))
    assert {'employee_id': emp, 'employee': employee.name, 'users': [user.username]} in plan['users_closed']
    assert {'employee_id': emp, 'employee': employee.name, 'column': 'cash_safe_box_id',
            'safe_id': 999999} in plan['links_cleared']
    assert db.session.get(AppUser, user.id).is_active is True, 'a dry run writes nothing'
    cleanup(by='المالك', now=datetime(2026, 11, 1), dry_run=False)
    assert db.session.get(AppUser, user.id).is_active is False and employee.cash_safe_box_id is None
