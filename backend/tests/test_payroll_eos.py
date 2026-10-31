"""The end-of-service provision, booked by each month's run (PAYROLL-5).

The owner, 1 Nov 2026 («اودع وانتقل»). On the 31 Oct copy no provision had
ever been booked and no employee had a hire date. The Labour Law (art. 84):
half a month's wage for each of the first five years, a month for each year
after, a part of a year by its days, on the actual wage. Each run books the
month's provision -- the entitlement at its end less what his account holds:

  - with no hire date nothing is booked, and the line says why;
  - a year's service is half a month; the next month books its days only;
  - past five years a year is a whole month;
  - a cut in the wage gives back what was booked over it;
  - the rates are the policy's; a role not mapped leaves the run a draft.

Run:
    python -m pytest tests/test_payroll_eos.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from models import Account, AccountingMapping, Employee, JournalEntry, JournalEntryLine, PayrollRun, db

POLICY = {'housing_ratio': 0.25, 'transport_ratio': 0.10, 'advance_cap_ratio': 0.10,
          'advance_installments': 3, 'attendance_enabled': False, 'day_divisor': 30,
          'overtime_premium_ratio': 0.5, 'eos_wage_base': 'gross', 'eos_first_years': 5,
          'eos_first_years_months': 0.5, 'eos_after_years_months': 1.0}
YEAR = 2041


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


@pytest.fixture
def eos_expense():
    AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='eos_expense').delete()
    account = Account(account_number=f'98{uuid.uuid4().int % 10**8:08d}', name='مصروف نهاية الخدمة', type='Expense')
    db.session.add(account)
    db.session.flush()
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='eos_expense',
                                     account_id=account.id, is_active=True))
    db.session.commit()
    return account


def _employee(headers, hire_date=None):
    assert _call('put', '/api/payroll/policy', headers, POLICY)[0] == 200
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'موظف خدمة {uuid.uuid4().hex[:6]}', 'is_active': True, 'hire_date': hire_date})
    assert code in (200, 201), body
    emp = body['id']
    assert _call('post', f'/api/employees/{emp}/salary-structures', headers,
                 {'effective_from': '2030-01-01', 'basic': 6000, 'housing': 1500, 'transport': 600})[0] == 201
    return emp


def _run(headers, month, emp):
    code, run = _call('post', '/api/payroll/runs', headers, {'month': month, 'year': YEAR})
    assert code == 201, run
    return run, next(e for e in run['entries'] if e['employee_id'] == emp)


def _approve(headers, run):
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/approve", headers)
    assert code == 200, body
    return next(e for e in body['entries'] if True) and body


def _eos_rows(run_id, emp):
    from services.employee_accounts import employee_account
    payable = employee_account(db.session.get(Employee, emp), 'eos_payable')
    entry = JournalEntry.query.filter_by(reference_type='payroll_run_accrual', reference_id=run_id).one()
    return round(sum((l.cash_credit or 0.0) - (l.cash_debit or 0.0)
                     for l in JournalEntryLine.query.filter_by(journal_entry_id=entry.id, account_id=payable.id)), 2)


def test_with_no_hire_date_nothing_is_booked_and_the_line_says_why(auth_headers):
    emp = _employee(auth_headers)
    run, line = _run(auth_headers, 4, emp)
    assert line['breakdown']['eos'] == {'reason': 'no_hire_date', 'provision': 0.0}
    assert _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)[0] == 200, \
        'the run is not stopped by it'


def test_a_year_is_half_a_month_and_the_next_month_books_its_days(auth_headers, eos_expense):
    emp = _employee(auth_headers, hire_date='2040-05-01')
    run, line = _run(auth_headers, 4, emp)
    assert (line['breakdown']['eos']['days'], line['breakdown']['eos']['provision']) == (365, 4050.0)
    _approve(auth_headers, run)
    assert _eos_rows(run['id'], emp) == 4050.0, 'credited to his end-of-service account'
    run, line = _run(auth_headers, 5, emp)
    assert line['breakdown']['eos']['booked'] == 4050.0
    assert line['breakdown']['eos']['provision'] == round(396 / 365 * 0.5 * 8100 - 4050, 2)
    assert line['net_salary'] == 8100.0, 'no part of his net'


def test_past_five_years_a_year_is_a_whole_month(auth_headers, eos_expense):
    emp = _employee(auth_headers, hire_date='2035-05-01')
    line = _run(auth_headers, 4, emp)[1]
    years = line['breakdown']['eos']['days'] / 365
    assert line['breakdown']['eos']['entitlement'] == round(5 * 0.5 * 8100 + (years - 5) * 8100, 2)


def test_a_cut_in_the_wage_gives_back_what_was_booked_over_it(auth_headers, eos_expense):
    emp = _employee(auth_headers, hire_date='2040-05-01')
    run = _run(auth_headers, 4, emp)[0]
    _approve(auth_headers, run)
    _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
          {'effective_from': f'{YEAR}-05-01', 'basic': 4000})
    run, line = _run(auth_headers, 5, emp)
    assert line['breakdown']['eos']['provision'] < 0
    _approve(auth_headers, run)
    assert _eos_rows(run['id'], emp) == line['breakdown']['eos']['provision'], 'debited back'


def test_the_rates_are_the_policy_s_and_an_unmapped_expense_leaves_a_draft(auth_headers):
    assert _call('put', '/api/payroll/policy', auth_headers, {**POLICY, 'eos_wage_base': 'net'})[0] == 400
    assert _call('put', '/api/payroll/policy', auth_headers, {**POLICY, 'eos_after_years_months': 13})[0] == 400
    AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='eos_expense').delete()
    db.session.commit()
    emp = _employee(auth_headers, hire_date='2040-05-01')
    run = _run(auth_headers, 4, emp)[0]
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    assert code == 409 and 'الربط المحاسبي' in body['error'], body
    assert db.session.get(PayrollRun, run['id']).status == 'draft'


def test_the_setup_tool_makes_the_end_of_service_expense_under_its_parent():
    from accounting.mappings import get_account_id_for_mapping
    from services.repair.payroll_accounts import setup
    AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='eos_expense').delete()
    parent = Account(account_number=f'97{uuid.uuid4().int % 100:02d}', name='مصاريف إدارية', type='Expense')
    liabilities = Account(account_number=f'96{uuid.uuid4().int % 100:02d}', name='أرصدة دائنة', type='Liability')
    gosi = Account(account_number=f'95{uuid.uuid4().int % 10**6:06d}', name='تأمينات', type='Expense')
    db.session.add_all([parent, liabilities, gosi])
    db.session.flush()
    setup(by='المالك', under=liabilities.account_number, contributions_expense=gosi.account_number,
          eos_expense_under=parent.account_number, dry_run=False)
    made = db.session.get(Account, get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'eos_expense'))
    assert (made.parent_id, made.type, made.name) == (parent.id, 'Expense', 'مصروف مكافأة نهاية الخدمة')


def test_with_its_policy_not_set_nothing_is_booked_and_the_run_goes_on(auth_headers):
    """No figure is seeded (the owner: «ابنِ هيكله ولا تضع أي أرقام»)."""
    import json
    from models import Settings
    emp = _employee(auth_headers, hire_date='2040-05-01')
    settings = Settings.query.first()
    settings.payroll_policy = json.dumps({k: v for k, v in POLICY.items() if not k.startswith('eos_')})
    db.session.commit()
    run, line = _run(auth_headers, 4, emp)
    assert line['breakdown']['eos'] == {'reason': 'policy_not_set', 'provision': 0.0}
    assert _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)[0] == 200
