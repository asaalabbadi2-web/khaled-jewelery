"""An employee's leaves, their balance, and their mark on his run (EMP-4).

The owner, 1 Nov 2026 («الإجازات: لِمَ لا، اقتراحك؟» -- «اودع وابدأ»). No
leave was kept; every figure is his to enter, none seeded.

  1. a kind unset holds no balance;
  2. an accruing kind earns from the hire date, the longer days after some
     years; one that does not has its days a calendar year;
  3. a leave does not overlap another, nor pass the balance where one is held;
  4. an unpaid leave lessens his run's days, and is not recorded in a month
     whose run is approved.

Run:
    python -m pytest tests/test_employee_leave.py -v
"""
import uuid
from datetime import date

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


def _employee(headers, hire_date=None):
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'موظف إجازة {uuid.uuid4().hex[:6]}', 'is_active': True, 'hire_date': hire_date})
    assert code in (200, 201), body
    return body['id']


def _kind(headers, **fields):
    code, body = _call('post', '/api/leave-types', headers, {'name': f'إجازة {uuid.uuid4().hex[:6]}', **fields})
    assert code == 201, body
    return body['id']


def _leave(headers, emp, kind, start, end, **fields):
    return _call('post', f'/api/employees/{emp}/leaves', headers,
                 {'type_id': kind, 'start_date': start, 'end_date': end, **fields})


def _balance(emp, kind):
    from models import Employee, LeaveType, db
    from services.employee_leave import balance
    return balance(db.session.get(Employee, emp), db.session.get(LeaveType, kind), date(2041, 6, 30))


def test_a_kind_unset_holds_no_balance(auth_headers):
    emp = _employee(auth_headers, hire_date='2040-01-01')
    kind = _kind(auth_headers, paid=True, accrues=True)
    assert _balance(emp, kind) is None
    assert _leave(auth_headers, emp, kind, '2041-03-01', '2041-03-30')[0] == 201, 'nothing to hold it to'


def test_an_accruing_kind_earns_from_the_hire_date_and_more_after_some_years(auth_headers):
    emp = _employee(auth_headers, hire_date='2040-07-01')            # a year to 30 Jun 2041
    kind = _kind(auth_headers, paid=True, accrues=True, days_per_year=21)
    assert _balance(emp, kind) == 21.0
    code, body = _leave(auth_headers, emp, kind, '2041-06-01', '2041-06-25')
    assert code == 400 and 'رصيد' in body['error'], '25 days of 21'
    assert _leave(auth_headers, emp, kind, '2041-06-01', '2041-06-10')[0] == 201
    assert _balance(emp, kind) == 11.0
    senior = _employee(auth_headers, hire_date='2033-07-01')          # eight years
    longer = _kind(auth_headers, paid=True, accrues=True, days_per_year=21, longer_after_years=5,
                   longer_days_per_year=30)
    assert _balance(senior, longer) == round(5 * 21 + 3 * 30, 2)
    assert _balance(_employee(auth_headers), longer) is None, 'no hire date, no balance'


def test_a_kind_that_does_not_accrue_has_its_days_a_calendar_year(auth_headers):
    emp = _employee(auth_headers, hire_date='2030-01-01')
    sick = _kind(auth_headers, paid=True, accrues=False, days_per_year=30)
    assert _leave(auth_headers, emp, sick, '2040-12-01', '2040-12-25')[0] == 201
    assert _balance(emp, sick) == 30.0, 'last year is not this year'


def test_a_leave_does_not_overlap_another_and_a_request_is_approved_or_rejected(auth_headers):
    emp = _employee(auth_headers)
    kind = _kind(auth_headers)
    assert _leave(auth_headers, emp, kind, '2041-03-10', '2041-03-05')[0] == 400, 'ends before it begins'
    _leave(auth_headers, emp, kind, '2041-03-01', '2041-03-10')
    assert _leave(auth_headers, emp, kind, '2041-03-08', '2041-03-12')[0] == 400
    code, request = _leave(auth_headers, emp, kind, '2041-04-01', '2041-04-02', status='requested')
    assert code == 201 and request['status'] == 'requested'
    assert _call('post', f"/api/employee-leaves/{request['id']}/approve", auth_headers)[1]['status'] == 'approved'


def test_an_unpaid_leave_lessens_the_run_and_is_not_recorded_in_an_approved_month(auth_headers):
    assert _call('put', '/api/payroll/policy', auth_headers, POLICY)[0] == 200
    emp = _employee(auth_headers)
    _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
          {'effective_from': '2041-01-01', 'basic': 6000, 'housing': 1500, 'transport': 600})
    unpaid = _kind(auth_headers, paid=False)
    assert _leave(auth_headers, emp, unpaid, '2041-04-11', '2041-04-15')[0] == 201
    code, run = _call('post', '/api/payroll/runs', auth_headers, {'month': 4, 'year': 2041})
    line = next(e for e in run['entries'] if e['employee_id'] == emp)
    assert (line['breakdown']['days'], line['breakdown']['unpaid_leave_days']) == (25, 5)
    assert line['net_salary'] == 6750.0, '25 of 30 days of 8,100'
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    assert _leave(auth_headers, emp, unpaid, '2041-04-20', '2041-04-21')[0] == 400, 'its run is approved'
    leave_id = _call('get', f'/api/employees/{emp}/leaves', auth_headers)[1]['leaves'][0]['id']
    assert _call('post', f'/api/employee-leaves/{leave_id}/cancel', auth_headers)[0] == 400
