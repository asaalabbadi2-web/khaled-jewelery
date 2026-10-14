"""CHART-002 step 3: an employee's accounts are linked; the structure is data.

The code found an employee's payables by the employee's name under parents it
knew by number (2400, 2410, 2420, 2310) and built those parents -- and 170,
1700, 240 -- by their 2026 numbers when missing; the gold custody group was
renamed, renumbered and pruned on every employee created. The owner, 14 Oct
2026: the parents are mapped roles, the employee's accounts explicit links.
"""
import uuid

import pytest

from app import app as flask_app
from models import Account, AccountingMapping, Employee, EmployeeAccount, db
from services.employee_accounts import PAYABLE_ROLES


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _create(headers, name):
    return flask_app.test_client().post('/api/employees', headers=headers, json={
        'name': name, 'employee_code': f'E-L-{uuid.uuid4().hex[:6]}'})


def test_a_new_employee_has_its_accounts_linked_under_the_mapped_parents(auth_headers):
    resp = _create(auth_headers, f'موظف ربط {uuid.uuid4().hex[:4]}')
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    employee = db.session.get(Employee, resp.get_json()['id'])
    links = {row.role: row.account for row in EmployeeAccount.query.filter_by(employee_id=employee.id)}
    assert set(links) == set(PAYABLE_ROLES)
    parents = {'salary_payable': '2400', 'commission_payable': '2410', 'eos_payable': '2420', 'bonus_payable': '2310'}
    for role, account in links.items():
        assert db.session.get(Account, account.parent_id).account_number == parents[role]
        assert employee.name in account.name
    assert db.session.get(Account, db.session.get(Account, employee.account_id).parent_id).account_number == '1700'


def test_a_renamed_employee_keeps_its_bonus_account(auth_headers):
    from services.bonus_accounts import employee_bonus_account
    resp = _create(auth_headers, f'موظف قبل {uuid.uuid4().hex[:4]}')
    employee = db.session.get(Employee, resp.get_json()['id'])
    account = employee_bonus_account(employee)
    employee.name = f'موظف بعد {uuid.uuid4().hex[:4]}'
    db.session.flush()
    assert employee_bonus_account(employee) == account       # the name no longer finds it


def test_an_unmapped_parent_refuses_and_builds_no_parent(auth_headers):
    rows = AccountingMapping.query.filter_by(account_type='employee_salary_payable_parent', is_active=True).all()
    for row in rows:
        row.is_active = False
    db.session.flush()
    groups_before = Account.query.filter(Account.name.like('ذمم الموظفين%')).count()
    resp = _create(auth_headers, f'موظف بلا أب {uuid.uuid4().hex[:4]}')
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert 'employee_salary_payable_parent' in resp.get_json()['error']
    assert Account.query.filter(Account.name.like('ذمم الموظفين%')).count() == groups_before


def test_every_structure_role_is_required():
    """A structure role the code asks for is one the nightly ROLE_NOT_MAPPED watches."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, REQUIRED_ROLES
    from services.employee_accounts import STRUCTURE_ROLES
    assert {(DEFAULT_MAPPING_OPERATION_TYPE, r) for r in STRUCTURE_ROLES} <= set(REQUIRED_ROLES)
