"""An employee's end of service and its final settlement (EMP-5).

The owner, 1 Nov 2026: «عند إنهاء الخدمة: هل يحسب النظام التسوية النهائية
ويقيّدها؟ نعم». Stopping an employee was a flag, nothing settled.

  1. previewed before approved; the award by the reason -- whole, by the
     policy's resignation shares (unset: not settled), none for art. 80;
  2. his accruing paid leave left is paid at the gross by the day divisor;
  3. approved with one entry, he and his users stopped, his plans ended;
  4. paid by one voucher at what the books owe, less his advance -- not while
     a run line of his is approved and unpaid; his bonuses paid with it;
  5. cancelled unpaid, reversed and he is active again; paid, not cancelled;
     its voucher cancelled, it is unpaid again.

Run:
    python -m pytest tests/test_employee_termination.py -v
"""
import uuid
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from models import (Account, AccountingMapping, AppUser, Employee, EmployeeBonus, EmployeeTermination,
                    JournalEntry, JournalEntryLine, db)

POLICY = {'housing_ratio': 0.25, 'transport_ratio': 0.10, 'advance_cap_ratio': 0.10,
          'advance_installments': 3, 'attendance_enabled': False, 'day_divisor': 30,
          'overtime_premium_ratio': 0.5, 'eos_wage_base': 'gross', 'eos_first_years': 5,
          'eos_first_years_months': 0.5, 'eos_after_years_months': 1.0}
RESIGNATION = {'eos_resign_min_years': 2, 'eos_resign_tier1_years': 5, 'eos_resign_tier2_years': 10,
               'eos_resign_tier1_share': 0.3333, 'eos_resign_tier2_share': 0.6667}


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


def _employee(headers, hire_date, policy=POLICY):
    assert _call('put', '/api/payroll/policy', headers, policy)[0] == 200
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'موظف إنهاء {uuid.uuid4().hex[:6]}', 'is_active': True, 'hire_date': hire_date})
    emp = body['id']
    _call('post', f'/api/employees/{emp}/salary-structures', headers,
          {'effective_from': '2030-01-01', 'basic': 6000, 'housing': 1500, 'transport': 600})
    return emp


def _preview(headers, emp, reason, last_day='2041-04-30'):
    return _call('post', f'/api/employees/{emp}/termination/preview', headers, {'reason': reason, 'last_day': last_day})


def test_the_award_is_by_the_reason(auth_headers, eos_expense):
    emp = _employee(auth_headers, '2036-05-01')                      # five years to 30 Apr 2041
    code, body = _preview(auth_headers, emp, 'employer_ended')
    assert code == 200 and body['eos']['award'] == 20250.0, body       # 5 x half of 8,100
    assert _preview(auth_headers, emp, 'art_80')[1]['eos']['award'] == 0.0
    code, body = _preview(auth_headers, emp, 'resignation')
    assert code == 400 and body['code'] == 'payroll_policy_not_set', 'its shares are the owner\'s'
    _call('put', '/api/payroll/policy', auth_headers, RESIGNATION)
    junior = _employee(auth_headers, '2038-05-01', {**POLICY, **RESIGNATION})   # three years
    assert _preview(auth_headers, junior, 'resignation')[1]['eos']['award'] == round(3 * 0.5 * 8100 * 0.3333, 2)
    assert _preview(auth_headers, _employee(auth_headers, '2040-05-01', {**POLICY, **RESIGNATION}),
                    'resignation')[1]['eos']['award'] == 0.0, 'below two years'


def test_his_leave_left_is_paid_at_the_gross_by_the_divisor(auth_headers, eos_expense):
    emp = _employee(auth_headers, '2040-05-01')
    _call('post', '/api/leave-types', auth_headers, {'name': f'سنوية {uuid.uuid4().hex[:6]}', 'paid': True,
                                                     'accrues': True, 'days_per_year': 21})
    body = _preview(auth_headers, emp, 'contract_end')[1]
    assert body['leave']['amount'] == 21 * 270.0, '21 days of 8,100 / 30'


def test_approved_with_one_entry_he_and_his_users_stopped(auth_headers, eos_expense):
    emp = _employee(auth_headers, '2036-05-01')
    user = AppUser(username=f'emp-{uuid.uuid4().hex[:6]}', role='employee', is_active=True, employee_id=emp)
    user.set_password('x')
    db.session.add(user)
    db.session.commit()
    code, body = _call('post', f'/api/employees/{emp}/termination', auth_headers,
                       {'reason': 'employer_ended', 'last_day': '2041-04-30'})
    assert code == 201 and body['users_closed'] == [user.username], body
    entry = db.session.get(JournalEntry, body['journal_entry_id'])
    lines = JournalEntryLine.query.filter_by(journal_entry_id=entry.id).all()
    assert round(sum(l.cash_debit or 0 for l in lines), 2) == round(sum(l.cash_credit or 0 for l in lines), 2) == 20250.0
    employee = db.session.get(Employee, emp)
    assert (employee.is_active, employee.termination_date) == (False, date(2041, 4, 30))
    assert _call('post', f'/api/employees/{emp}/termination', auth_headers,
                 {'reason': 'employer_ended', 'last_day': '2041-04-30'})[0] == 400, 'one standing termination'


def _owe(employee, amount):
    from dual_system_helpers import create_dual_journal_entry
    other = Account(account_number=f'97{uuid.uuid4().int % 10**6:06d}', name='مقابل', type='Asset')
    entry = JournalEntry(date=datetime(2041, 1, 5), description='سلفة', entry_type='عادي', is_posted=True,
                         is_draft=False, created_by='t')
    db.session.add_all([other, entry])
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=employee.account_id, cash_debit=amount)
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=other.id, cash_credit=amount)
    db.session.commit()


def test_paid_by_one_voucher_less_his_advance_and_his_bonuses_with_it(auth_headers, eos_expense):
    emp = _employee(auth_headers, '2036-05-01')
    _owe(db.session.get(Employee, emp), 1000.0)
    bonus = EmployeeBonus(employee_id=emp, bonus_type='fixed', amount=500.0, status='pending',
                          period_start=date(2041, 3, 1), period_end=date(2041, 3, 31))
    db.session.add(bonus)
    db.session.commit()
    assert _call('post', f'/api/bonuses/{bonus.id}/approve', auth_headers, {})[0] == 200
    termination = _call('post', f'/api/employees/{emp}/termination', auth_headers,
                        {'reason': 'employer_ended', 'last_day': '2041-04-30'})[1]
    assert termination['settlement']['net'] == 20250.0 + 500.0 - 1000.0
    account = _call('get', '/api/payroll/payment-accounts', auth_headers)[1][0]['id']
    code, body = _call('post', f"/api/employee-terminations/{termination['id']}/pay", auth_headers,
                       {'payment_account_id': account})
    assert code == 200 and body['status'] == 'paid', body
    assert db.session.get(EmployeeBonus, bonus.id).status == 'paid'
    assert _call('post', f"/api/employee-terminations/{termination['id']}/cancel", auth_headers)[0] == 400
    code, _ = _call('post', f"/api/vouchers/{body['voucher_id']}/cancel", auth_headers, {'reason': 'خطأ'})
    assert code == 200
    db.session.expire_all()
    assert db.session.get(EmployeeTermination, termination['id']).status == 'approved', 'unpaid again'


def test_cancelled_unpaid_it_is_reversed_and_he_is_active_again(auth_headers, eos_expense):
    emp = _employee(auth_headers, '2036-05-01')
    termination = _call('post', f'/api/employees/{emp}/termination', auth_headers,
                        {'reason': 'employer_ended', 'last_day': '2041-04-30'})[1]
    code, body = _call('post', f"/api/employee-terminations/{termination['id']}/cancel", auth_headers)
    assert code == 200 and body['status'] == 'cancelled', body
    assert JournalEntry.query.filter_by(reference_type='eos_settlement_reversal',
                                        reference_id=termination['id']).count() == 1
    employee = db.session.get(Employee, emp)
    assert (employee.is_active, employee.termination_date) == (True, None)


def test_not_paid_while_a_run_line_of_his_is_approved_and_unpaid(auth_headers, eos_expense):
    emp = _employee(auth_headers, '2036-05-01')
    termination = _call('post', f'/api/employees/{emp}/termination', auth_headers,
                        {'reason': 'employer_ended', 'last_day': '2041-04-20'})[1]
    code, run = _call('post', '/api/payroll/runs', auth_headers, {'month': 4, 'year': 2041})
    line = next(e for e in run['entries'] if e['employee_id'] == emp)
    assert line['breakdown']['days'] == 20, 'his last month prorated by his last day'
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    account = _call('get', '/api/payroll/payment-accounts', auth_headers)[1][0]['id']
    code, body = _call('post', f"/api/employee-terminations/{termination['id']}/pay", auth_headers,
                       {'payment_account_id': account})
    assert code == 400 and 'مسيره' in body['error'], body
