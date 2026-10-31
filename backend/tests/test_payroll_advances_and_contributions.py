"""The run's deductions and its accrual at the gross: advances, contributions, absence, penalties (PAYROLL-3).

The owner, 1 Nov 2026: «طبّق النظام الأفضل والأشمل» and «طبّق النظام المتكامل
والأرقام دعها عليّ». On the 31 Oct copy the accrual was the net on the salary
expense; the advances (104,000) sat in the employees' accounts with no plan;
the contributions were a manual voucher on the expense. Now:

  - an advance plan is the books' balance, never more; its installment within
    the policy's share of the wage unless the employee consented, noted; the
    run takes it, no more than is left; a cancelled run gives it back;
  - the contributions are his scheme's on the wage registered for them;
  - the accrual: Dr salary expense (gross + additions - absence), Dr the
    employer's share; Cr his net, the contributions payable (both shares),
    his advance account, the penalties payable;
  - a role not mapped refuses the approval -- the run stays a draft.

Run:
    python -m pytest tests/test_payroll_advances_and_contributions.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from models import Account, AccountingMapping, Employee, JournalEntry, JournalEntryLine, PayrollRun, db

POLICY = {'housing_ratio': 0.25, 'transport_ratio': 0.10, 'advance_cap_ratio': 0.10,
          'advance_installments': 3, 'attendance_enabled': False, 'day_divisor': 30,
          'overtime_premium_ratio': 0.5}
MONTH, YEAR = 4, 2041


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def _account(name, kind, digits=8):
    account = Account(account_number=f'98{uuid.uuid4().int % 10**digits:0{digits}d}', name=name, type=kind)
    db.session.add(account)
    db.session.flush()
    return account


@pytest.fixture
def mapped():
    """The three roles, mapped as the setup tool maps them."""
    accounts = {}
    for role, name, kind in (('gosi_expense', 'مصروف تأمينات', 'Expense'),
                             ('gosi_payable', 'تأمينات مستحقة', 'Liability'),
                             ('payroll_penalties_payable', 'جزاءات مستحقة', 'Liability')):
        AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                          account_type=role).delete()
        accounts[role] = _account(name, kind)
        db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=role,
                                         account_id=accounts[role].id, is_active=True))
    db.session.commit()          # a savepoint under the fence: a refused request's rollback keeps it
    return accounts


@pytest.fixture
def employee(auth_headers):
    """8,100 a month (6,000 + 1,500 + 600) and 9,000 owed on his advance account."""
    assert _call('put', '/api/payroll/policy', auth_headers, POLICY)[0] == 200
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف سلف {uuid.uuid4().hex[:6]}', 'is_active': True})
    assert code in (200, 201), body
    emp = body['id']
    assert _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
                 {'effective_from': f'{YEAR}-01-01', 'basic': 6000, 'housing': 1500, 'transport': 600})[0] == 201
    _owe(db.session.get(Employee, emp), 9000.0)
    return emp


def _owe(employee, amount):
    from dual_system_helpers import create_dual_journal_entry
    other = _account('مقابل سلفة', 'Asset')
    entry = JournalEntry(date=datetime(2041, 1, 5), description='سلفة', entry_type='عادي', is_posted=True,
                         is_draft=False,
                         posted_at=datetime(2041, 1, 5), posted_by='t', created_by='t')
    db.session.add(entry)
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=employee.account_id, cash_debit=amount)
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=other.id, cash_credit=amount)
    db.session.commit()          # a savepoint under the fence: a refused request's rollback keeps it


def _plan(headers, emp, **fields):
    body = {'start_month': MONTH, 'start_year': YEAR, **fields}
    return _call('post', f'/api/employees/{emp}/advance-plans', headers, body)


def _run(headers):
    code, run = _call('post', '/api/payroll/runs', headers, {'month': MONTH, 'year': YEAR})
    assert code == 201, run
    return run


def _line(run, emp):
    return next(e for e in run['entries'] if e['employee_id'] == emp)


def _accrual_lines(run_id):
    entry = JournalEntry.query.filter_by(reference_type='payroll_run_accrual', reference_id=run_id).one()
    rows = {}
    for line in JournalEntryLine.query.filter_by(journal_entry_id=entry.id, is_deleted=False):
        rows[line.account_id] = round(rows.get(line.account_id, 0.0) + (line.cash_debit or 0.0)
                                      - (line.cash_credit or 0.0), 2)
    return rows


# ── advances ───────────────────────────────────────────────────────────────────

def test_an_advance_plan_is_the_books_balance_never_more(auth_headers, employee):
    assert _plan(auth_headers, employee, amount=10000, installment=800)[0] == 400, 'the books say 9,000'
    code, plan = _plan(auth_headers, employee, amount=2000, installment=800)
    assert code == 201 and plan['remaining'] == 2000.0, plan
    assert _plan(auth_headers, employee, amount=7500, installment=800)[0] == 400, '7,000 is left unplanned'
    body = _call('get', f'/api/employees/{employee}/advance-plans', auth_headers)[1]
    assert (body['account_balance'], body['unplanned']) == (9000.0, 7000.0)


def test_an_installment_is_within_the_cap_unless_he_consented_noted(auth_headers, employee):
    code, body = _plan(auth_headers, employee, amount=3000)          # 3 installments of 1,000
    assert code == 400 and body['code'] == 'advance_cap_exceeded', 'more than 810, a tenth of 8,100'
    assert _plan(auth_headers, employee, amount=3000, consent=True)[0] == 400, 'his consent, noted'
    code, plan = _plan(auth_headers, employee, amount=3000, consent=True, consent_note='إقرار 3 أبريل')
    assert code == 201 and plan['installment'] == 1000.0, plan


def test_the_run_takes_the_installment_and_a_cancelled_run_gives_it_back(auth_headers, employee):
    plan = _plan(auth_headers, employee, amount=2000, installment=800)[1]
    run = _run(auth_headers)
    line = _line(run, employee)
    assert [d['amount'] for d in line['breakdown']['deductions'] if d['kind'] == 'advance'] == [800.0]
    assert line['net_salary'] == 7300.0
    assert _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)[0] == 200
    advance_account = db.session.get(Employee, employee).account_id
    assert _accrual_lines(run['id'])[advance_account] == -800.0, 'credited to his advance account'
    plans = _call('get', f'/api/employees/{employee}/advance-plans', auth_headers)[1]['plans']
    assert plans[0]['remaining'] == 1200.0
    _call('post', f"/api/payroll/runs/{run['id']}/cancel", auth_headers)
    plans = _call('get', f'/api/employees/{employee}/advance-plans', auth_headers)[1]['plans']
    assert plans[0]['remaining'] == 2000.0, 'a cancelled run gives it back'
    assert plan['id'] == plans[0]['id']


def test_the_month_s_installments_together_are_within_the_cap(auth_headers, employee):
    _plan(auth_headers, employee, amount=1800, installment=600)
    _plan(auth_headers, employee, amount=1800, installment=600)
    line = _line(_run(auth_headers), employee)
    assert [d['amount'] for d in line['breakdown']['deductions'] if d['kind'] == 'advance'] == [600.0, 210.0]


# ── contributions ──────────────────────────────────────────────────────────────

def _scheme(headers, emp, wage):
    code, scheme = _call('post', '/api/contribution-schemes', headers, {'name': f'خطة {uuid.uuid4().hex[:6]}'})
    url = f"/api/contribution-schemes/{scheme['id']}/components"
    for row in ({'code': 'annuities', 'name': 'المعاشات', 'employee_rate': 9, 'employer_rate': 9},
                {'code': 'hazards', 'name': 'الأخطار المهنية', 'employee_rate': 0, 'employer_rate': 2}):
        assert _call('post', url, headers, {**row, 'base': 'basic_housing', 'base_cap': 45000,
                                            'effective_from': '2026-01-01'})[0] == 201
    code, body = _call('put', f'/api/employees/{emp}', headers,
                       {'contribution_scheme_id': scheme['id'], 'contribution_wage': wage})
    assert code == 200 and body['contribution_wage'] == wage, body


def test_the_accrual_is_at_the_gross_with_the_contributions_on_the_registered_wage(auth_headers, employee, mapped):
    _scheme(auth_headers, employee, 4000.0)
    run = _run(auth_headers)
    line = _line(run, employee)
    assert line['net_salary'] == 7740.0, '8,100 less 9% of 4,000'
    assert sum(r['amount'] for r in line['breakdown']['employer_contributions']) == 440.0
    assert _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)[0] == 200
    rows = _accrual_lines(run['id'])
    assert rows[mapped['gosi_expense'].id] == 440.0
    assert rows[mapped['gosi_payable'].id] == -800.0, 'both shares owed'
    assert round(sum(rows.values()), 2) == 0
    salary_expense = max(rows.values())
    assert salary_expense == 8100.0, 'the gross, not the net'


def test_a_contribution_with_its_role_unmapped_leaves_the_run_a_draft(auth_headers, employee):
    for role in ('gosi_expense', 'gosi_payable'):
        AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=role).delete()
    db.session.commit()
    _scheme(auth_headers, employee, 4000.0)
    run = _run(auth_headers)
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    assert code == 409 and 'الربط المحاسبي' in body['error'], body
    assert db.session.get(PayrollRun, run['id']).status == 'draft'
    assert _call('put', f'/api/employees/{employee}', auth_headers, {'contribution_wage': -1})[0] == 400


# ── absence and penalties ──────────────────────────────────────────────────────

def test_absence_lessens_the_expense_and_a_penalty_is_owed_to_its_account(auth_headers, employee, mapped):
    run = _run(auth_headers)
    line = _line(run, employee)
    url = f"/api/payroll/runs/{run['id']}/lines/{line['id']}"
    assert _call('put', url, auth_headers, {'deductions': [{'label': 'قسط', 'amount': 5, 'kind': 'advance'}]})[0] \
        == 409, 'a reckoned deduction is not keyed'
    code, body = _call('put', url, auth_headers, {'deductions': [
        {'label': 'غياب يوم', 'amount': 200, 'kind': 'absence'},
        {'label': 'تأخر متكرر', 'amount': 100, 'kind': 'penalty'}]})
    assert code == 200 and _line(body, employee)['net_salary'] == 7800.0, body
    assert _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)[0] == 200
    rows = _accrual_lines(run['id'])
    assert rows[mapped['payroll_penalties_payable'].id] == -100.0
    assert max(rows.values()) == 7900.0, 'absence is not earned: 8,100 - 200'


# ── the setup tool ─────────────────────────────────────────────────────────────

def test_the_setup_tool_makes_the_two_accounts_and_maps_the_three_roles_once():
    from accounting.mappings import get_account_id_for_mapping
    from services.repair.payroll_accounts import setup
    for role in ('gosi_expense', 'gosi_payable', 'payroll_penalties_payable'):
        AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=role).delete()
    parent, expense = _account('أرصدة دائنة أخرى', 'Liability', 2), _account('تأمينات إجتماعية', 'Expense')
    plan = setup(by='t', under=parent.account_number, contributions_expense=expense.account_number)
    assert len(plan['made']) == 2 and not get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gosi_payable')
    setup(by='المالك', under=parent.account_number, contributions_expense=expense.account_number, dry_run=False)
    payable = db.session.get(Account, get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gosi_payable'))
    assert payable.parent_id == parent.id and payable.type == 'Liability'
    assert get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gosi_expense') == expense.id
    again = setup(by='t', under=parent.account_number, contributions_expense=expense.account_number, dry_run=False)
    assert again['made'] == [] and len(again['kept']) == 3
