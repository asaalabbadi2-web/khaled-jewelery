"""An employee's contract and documents, and what of them nears its end (EMP-3).

The owner, 1 Nov 2026: «ما يُعمل به في الأنظمة المماثلة، وإن كان ممكنًا أن يكون
ضبط الأيام اختياريًا». On the 1 Nov copy nothing of a contract or a document
was kept.

  - a fixed-term contract ends after it begins, an open one has no end, a
    probation ends within 180 days (art. 53);
  - a document ends no earlier than it is issued; the latest of a kind is the
    one followed -- a renewal ends the alert;
  - an alert is said by the days the owner set -- unset, nothing; an ended one
    too, until renewed; a stopped employee's not;
  - the manager's dashboard counts them; the file lists them.

Run:
    python -m pytest tests/test_employee_contracts_documents.py -v
"""
import uuid
from datetime import date, timedelta

import pytest
from flask import g

from app import app as flask_app
from models import Employee, db

TODAY = date(2041, 6, 1)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def _employee(headers):
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'موظف وثائق {uuid.uuid4().hex[:6]}', 'is_active': True})
    assert code in (200, 201), body
    return body['id']


def _kind(headers, alert_days=None):
    code, body = _call('post', '/api/employee-document-types', headers,
                       {'name': f'إقامة {uuid.uuid4().hex[:6]}', 'alert_days': alert_days})
    assert code == 201, body
    return body


def _ours(emp):
    from services.employee_documents import expiring
    return [r for r in expiring(TODAY) if r['employee_id'] == emp]


def test_a_contract_keeps_the_law_s_shape(auth_headers):
    emp = _employee(auth_headers)
    url = f'/api/employees/{emp}/contracts'
    assert _call('post', url, auth_headers, {'kind': 'fixed', 'start_date': '2041-01-01'})[0] == 400, 'its end'
    assert _call('post', url, auth_headers, {'kind': 'indefinite', 'start_date': '2041-01-01',
                                             'end_date': '2042-01-01'})[0] == 400
    assert _call('post', url, auth_headers, {'kind': 'fixed', 'start_date': '2041-01-01', 'end_date': '2042-01-01',
                                             'probation_end': '2041-08-01'})[0] == 400, 'art. 53: 180 days'
    code, body = _call('post', url, auth_headers, {'kind': 'fixed', 'start_date': '2041-01-01',
                                                   'end_date': '2041-12-31', 'probation_end': '2041-03-31'})
    assert code == 201, body
    _call('post', url, auth_headers, {'kind': 'indefinite', 'start_date': '2042-01-01'})
    from services.employee_documents import contract_on
    assert contract_on(emp, date(2041, 6, 1)).kind == 'fixed'
    assert contract_on(emp, date(2042, 6, 1)).kind == 'indefinite', 'the renewal in force from its day'


def test_a_document_is_alerted_by_its_kind_s_days_and_its_renewal_ends_it(auth_headers):
    emp = _employee(auth_headers)
    unset, kind = _kind(auth_headers), _kind(auth_headers, alert_days=30)
    url = f'/api/employees/{emp}/documents'
    assert _call('post', url, auth_headers, {'type_id': kind['id'], 'issued_on': '2041-05-01',
                                             'expires_on': '2041-04-01'})[0] == 400, 'ends before its issue'
    _call('post', url, auth_headers, {'type_id': unset['id'], 'expires_on': str(TODAY + timedelta(days=5))})
    _call('post', url, auth_headers, {'type_id': kind['id'], 'number': '2', 'expires_on': str(TODAY + timedelta(days=20))})
    rows = _ours(emp)
    assert [(r['label'], r['days_left']) for r in rows] == [(kind['name'], 20)], 'the kind with no days says nothing'
    _call('post', url, auth_headers, {'type_id': kind['id'], 'number': '3', 'expires_on': '2043-06-01'})
    assert _ours(emp) == [], 'renewed: the latest of its kind is followed'


def test_an_ended_document_is_said_until_renewed_and_a_stopped_employee_s_never(auth_headers):
    emp = _employee(auth_headers)
    kind = _kind(auth_headers, alert_days=0)
    _call('post', f'/api/employees/{emp}/documents', auth_headers,
          {'type_id': kind['id'], 'expires_on': str(TODAY - timedelta(days=3))})
    assert [r['days_left'] for r in _ours(emp)] == [-3]
    db.session.get(Employee, emp).is_active = False
    db.session.commit()
    assert _ours(emp) == []


def test_a_contract_s_end_and_probation_by_the_policy_s_days(auth_headers):
    emp = _employee(auth_headers)
    _call('post', f'/api/employees/{emp}/contracts', auth_headers,
          {'kind': 'fixed', 'start_date': str(TODAY - timedelta(days=30)), 'end_date': str(TODAY + timedelta(days=40)),
           'probation_end': str(TODAY + timedelta(days=10))})
    _call('put', '/api/payroll/policy', auth_headers, {'contract_alert_days': None})
    assert _ours(emp) == [], 'unset, nothing is said'
    assert _call('put', '/api/payroll/policy', auth_headers, {'contract_alert_days': 45})[0] == 200
    assert [(r['kind'], r['days_left']) for r in _ours(emp)] == [('probation', 10), ('contract', 40)]


def test_the_dashboard_counts_them_and_the_file_lists_them(auth_headers):
    from services.dashboard_alerts import alerts
    emp = _employee(auth_headers)
    kind = _kind(auth_headers, alert_days=30)
    _call('post', f'/api/employees/{emp}/documents', auth_headers,
          {'type_id': kind['id'], 'expires_on': str(TODAY + timedelta(days=7))})
    wrong = alerts([], today=TODAY)
    assert any(r['employee_id'] == emp for r in wrong['expiring_documents'])
    assert wrong['total'] >= len(wrong['expiring_documents'])
    file = _call('get', f'/api/employees/{emp}/file', auth_headers)[1]
    assert [d['type'] for d in file['documents']] == [kind['name']] and file['contract'] is None
