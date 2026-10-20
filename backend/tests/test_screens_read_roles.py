"""CHART-002 release 5c: the screens read an account by its role or its link,
from the server -- never by a number.

The voucher screen found an employee's salary payable by «2400» and the name,
their bonus payable by «2310», their personal account by «170»/«171», the
expenses by «5», and preselected 1400 «ضريبة المدخلات» for an advance refund;
the employees screen scored accounts by «2400» and the name. The server now
hands them the links (an employee's payable_accounts) and the groups
(/app-config account_groups: each a mapped role and the ids under it).
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Employee, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_an_employee_carries_its_account_links():
    from services.employee_accounts import ensure_payable_accounts
    employee = Employee(employee_code=f'E-{uuid.uuid4().hex[:6]}', name=f'موظف {uuid.uuid4().hex[:4]}', salary=1)
    db.session.add(employee)
    db.session.flush()
    accounts = ensure_payable_accounts(employee)

    links = employee.to_dict()['payable_accounts']

    assert links == {role: account.id for role, account in
                     zip(('salary_payable', 'commission_payable', 'eos_payable', 'bonus_payable'), accounts)}


def test_the_app_config_hands_the_groups_by_role(auth_headers):
    from accounting.chart_tree import subtree_ids
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    g.pop('current_user', None)
    config = flask_app.test_client().get('/api/app-config', headers=auth_headers).get_json()
    groups = config['account_groups']
    for name, role in (('employee_personal', 'employee_personal_parent'),
                       ('employee_salary_payable', 'employee_salary_payable_parent'),
                       ('employee_bonus_payable', 'employee_bonus_payable_parent'),
                       ('expenses', 'expenses_root'),
                       # The expense template's choice: operating expenses only,
                       # not purchases or cost of sales (the owner, 20 Oct 2026).
                       ('operating_expenses', 'operating_expenses_root')):
        account_id = require_account(DEFAULT_MAPPING_OPERATION_TYPE, role)
        assert groups[name]['account_id'] == account_id, name
        assert set(groups[name]['subtree_ids']) == subtree_ids(account_id), name
