"""His own safe, asked for by its kind; the repair button gone (HR-UX ط5).

The owner, 2 Nov 2026 («اعتمد»): «إصلاح حسابات وخزائن الموظف» made a cash
and a gold safe of his own in one press -- an employee on the main safe was
moved onto a new one nobody asked for. What it alone did is now asked for by
its name, one kind at a time, and only while he has none linked.

Run:
    python -m pytest tests/test_employee_own_safe.py -v
"""
import json
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import AuditLog, Employee, SafeBox, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def _employee(headers):
    code, body = _call('post', '/api/employees', headers, {'name': f'موظف خزنة {uuid.uuid4().hex[:6]}'})
    assert code in (200, 201), body
    return body['id']


def test_a_safe_of_his_own_is_made_by_its_kind_only_while_he_has_none(auth_headers):
    emp = _employee(auth_headers)
    assert db.session.get(Employee, emp).cash_safe_box_id in (None, 0), 'on the main safe'
    code, body = _call('post', f'/api/employees/{emp}/own-safe', auth_headers, {'kind': 'cash'})
    assert code == 201, body
    safe = db.session.get(SafeBox, body['safe_box_id'])
    assert safe is not None and safe.safe_type == 'cash'
    employee = db.session.get(Employee, emp)
    assert employee.cash_safe_box_id == safe.id
    assert employee.gold_safe_box_id in (None, 0), 'one kind asked, one made'
    code, body = _call('post', f'/api/employees/{emp}/own-safe', auth_headers, {'kind': 'cash'})
    assert (code, body.get('code')) == (409, 'employee_has_a_safe'), body
    assert _call('post', f'/api/employees/{emp}/own-safe', auth_headers, {'kind': 'silver'})[0] == 400
    changes = [json.loads(row.details or '{}').get('changes', {})
               for row in AuditLog.query.filter_by(entity_type='Employee', entity_id=emp,
                                                  action='update_employee')]
    assert any('cash_safe_box_id' in c for c in changes), 'his file\'s change recorded'


def test_the_repair_that_made_both_unasked_is_gone(auth_headers):
    emp = _employee(auth_headers)
    assert _call('post', f'/api/employees/{emp}/ensure-setup', auth_headers, {})[0] in (404, 405)
    assert _call('post', '/api/employees/bulk-ensure-setup', auth_headers, {})[0] in (404, 405)
