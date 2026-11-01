"""The employee's portal: his own, and nobody else's (EMP-PORTAL-1).

The owner, 1 Nov 2026 («انتقل لبوابة الموظف»). Each employee, signed in as
himself, sees his payslips, leave, advance, bonuses and goals, and asks for
leave. The security laws (§5, Law 5):

  1. the employee is the session's: an id in the request moves nothing; a user
     with no employee has no portal;
  2. another's payslip is not found; a draft line of his own is not shown;
  3. his leave asked is a request whatever he sends -- the manager approves;
     he cancels his undecided request alone, not another's nor an approved one.

Run:
    python -m pytest tests/test_employee_portal.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, EmployeeLeave, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def _employee(headers, name):
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'{name} {uuid.uuid4().hex[:6]}', 'is_active': True})
    assert code in (200, 201), body
    return body['id']


def _signed_in_as(employee_id):
    user = AppUser(username=f'portal-{uuid.uuid4().hex[:6]}', role='employee', is_active=True,
                   employee_id=employee_id, password_hash='x')
    db.session.add(user)
    db.session.commit()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _line(headers, emp, month, status):
    """An entry made one by one before the runs, as the books hold them (law 7:
    none is made now; services/payroll_laws)."""
    from models import Payroll
    entry = Payroll(employee_id=emp, month=month, year=2041, basic_salary=7000.0, allowances=0.0,
                    deductions=0.0, net_salary=7000.0, status=status, created_by='t')
    db.session.add(entry)
    db.session.commit()                                    # a savepoint under the fence
    return entry.id


def test_his_portal_is_his_own_and_another_s_payslip_is_not_found(auth_headers):
    mine, other = _employee(auth_headers, 'موظف بوابة'), _employee(auth_headers, 'غيره')
    my_line, draft = _line(auth_headers, mine, 3, 'approved'), _line(auth_headers, mine, 4, 'pending')
    their_line = _line(auth_headers, other, 3, 'approved')
    me = _signed_in_as(mine)
    code, body = _call('get', '/api/me/portal', me)
    assert code == 200 and [p['id'] for p in body['payslips']] == [my_line], 'his approved line alone'
    assert _call('get', f'/api/me/payslips/{my_line}', me)[0] == 200
    assert _call('get', f'/api/me/payslips/{their_line}', me)[0] == 404, 'another\'s: not found'
    assert _call('get', f'/api/me/payslips/{draft}', me)[0] == 404, 'a draft is not his payslip yet'
    assert _call('get', f'/api/me/portal?employee_id={other}', me)[1]['employee']['name'].startswith('موظف بوابة')


def test_a_user_with_no_employee_has_no_portal(auth_headers):
    code, body = _call('get', '/api/me/portal', auth_headers)
    assert code == 404 and body['code'] == 'no_employee'


def test_his_leave_asked_is_a_request_and_he_cancels_his_own_undecided_alone(auth_headers):
    mine, other = _employee(auth_headers, 'موظف إجازة'), _employee(auth_headers, 'غيره')
    code, kind = _call('post', '/api/leave-types', auth_headers, {'name': f'نوع {uuid.uuid4().hex[:6]}'})
    me = _signed_in_as(mine)
    code, body = _call('post', '/api/me/leaves', me, {'type_id': kind['id'], 'start_date': '2041-05-01',
                                                     'end_date': '2041-05-03', 'status': 'approved',
                                                     'employee_id': other})
    assert code == 201 and body['status'] == 'requested' and body['employee_id'] == mine, body
    theirs = _call('post', f'/api/employees/{other}/leaves', auth_headers,
                   {'type_id': kind['id'], 'start_date': '2041-05-01', 'end_date': '2041-05-02',
                    'status': 'requested'})[1]
    assert _call('post', f"/api/me/leaves/{theirs['id']}/cancel", me)[0] == 404, 'another\'s: not found'
    approved = _call('post', f"/api/employee-leaves/{body['id']}/approve", auth_headers)[1]
    assert approved['status'] == 'approved', 'the manager approves it'
    assert _call('post', f"/api/me/leaves/{body['id']}/cancel", me)[0] == 409, 'an approved leave is the manager\'s'
    code, again = _call('post', '/api/me/leaves', me, {'type_id': kind['id'], 'start_date': '2041-06-01',
                                                      'end_date': '2041-06-01'})
    assert _call('post', f"/api/me/leaves/{again['id']}/cancel", me)[1]['status'] == 'cancelled'
    assert db.session.get(EmployeeLeave, theirs['id']).status == 'requested'
