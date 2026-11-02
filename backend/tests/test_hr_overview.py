"""The HR hub's overview: indicators, employees, what needs doing -- each from its owner (HR-UX ر1).

The owner, 1 Nov 2026 («اعتمد» the one-screen design). On the 1 Nov copy:
five active and two stopped, September's 42,000, five with data missing,
October's run not drafted, the end of service's figures unset.

Run:
    python -m pytest tests/test_hr_overview.py -v
"""
import uuid
from datetime import date

import pytest
from flask import g

from app import app as flask_app
from models import db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})



def _entry(employee_id, month, year=2041, status='approved', basic=7000.0):
    """An entry made one by one before the runs, as the books hold them (law 7:
    none is made now; services/payroll_laws)."""
    from models import Payroll
    entry = Payroll(employee_id=employee_id, month=month, year=year, basic_salary=basic, allowances=0.0,
                    deductions=0.0, net_salary=basic, status=status, created_by='t')
    db.session.add(entry)
    db.session.commit()                                    # a savepoint under the fence
    return entry.id

def test_the_overview_says_its_employees_and_what_needs_doing(auth_headers):
    from services.hr_overview import overview
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف مركز {uuid.uuid4().hex[:6]}', 'is_active': True})
    emp = body['id']
    _entry(emp, 9)
    result = overview(today=date(2041, 11, 1))
    row = next(r for r in result['employees'] if r['id'] == emp)
    assert row['advance_gold'] == {}, 'his gold advance, by karat (the owner, 2 Nov 2026)'
    assert row['last_payroll']['month'] == 9 and row['gross'] is None, 'no structure: none said'
    assert 'تاريخ التعيين' in row['missing']
    kinds = {i['kind'] for i in result['followup']}
    assert 'run_missing' in kinds, 'October drafted by no run and no line'
    assert 'missing_data' in kinds
    assert result['kpis']['month_cost']['month'] == 9
    assert _call('get', '/api/hr/overview', auth_headers)[0] == 200
