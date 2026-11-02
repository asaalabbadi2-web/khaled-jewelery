"""An approved bonus is paid with the salary, in the month's run (PAYROLL-4).

The owner, 1 Nov 2026 (decision 4, «المكافآت: ما تنصح به أنت»). On the 31 Oct
copy five approved bonuses (14,135) were unpaid; «add to payroll» had marked a
bonus paid with no entry, and was removed (24 Oct). A bonus is expensed when
approved (bonus expense / his bonus payable). In the run:

  - an approved unpaid bonus is the line's, in its net;
  - the accrual moves it -- Dr his bonus payable -- and spends it no second time;
  - the line's voucher pays it and marks it paid;
  - while it is the line's it is not paid nor reversed alone; a draft may let
    it go, and a cancelled run lets it go.

Run:
    python -m pytest tests/test_payroll_bonuses.py -v
"""
import uuid
from datetime import date

import pytest
from flask import g

from app import app as flask_app
from models import Employee, EmployeeBonus, JournalEntry, JournalEntryLine, db

POLICY = {'housing_ratio': 0.25, 'transport_ratio': 0.10, 'advance_cap_ratio': 0.10,
          'advance_installments': 3, 'attendance_enabled': False, 'day_divisor': 30,
          'overtime_premium_ratio': 0.5, 'eos_wage_base': 'gross', 'eos_first_years': 5,
          'eos_first_years_months': 0.5, 'eos_after_years_months': 1.0}
MONTH, YEAR = 4, 2041


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


@pytest.fixture
def employee(auth_headers):
    assert _call('put', '/api/payroll/policy', auth_headers, POLICY)[0] == 200
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف مكافأة {uuid.uuid4().hex[:6]}', 'is_active': True})
    assert code in (200, 201), body
    emp = body['id']
    assert _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
                 {'effective_from': f'{YEAR}-01-01', 'basic': 6000, 'housing': 1500, 'transport': 600})[0] == 201
    return emp


def _approved_bonus(headers, emp, amount=1500.0, month=3):
    bonus = EmployeeBonus(employee_id=emp, bonus_type='fixed', amount=amount, status='pending',
                          period_start=date(YEAR, month, 1), period_end=date(YEAR, month, 28))
    db.session.add(bonus)
    db.session.commit()
    code, body = _call('post', f'/api/bonuses/{bonus.id}/approve', headers, {})
    assert code == 200, body
    return bonus.id


def _run(headers):
    code, run = _call('post', '/api/payroll/runs', headers, {'month': MONTH, 'year': YEAR})
    assert code == 201, run
    return run


def _line(run, emp):
    return next(e for e in run['entries'] if e['employee_id'] == emp)


def _accrual(run_id):
    entry = JournalEntry.query.filter_by(reference_type='payroll_run_accrual', reference_id=run_id).one()
    rows = {}
    for line in JournalEntryLine.query.filter_by(journal_entry_id=entry.id, is_deleted=False):
        rows[line.account_id] = round(rows.get(line.account_id, 0.0) + (line.cash_debit or 0.0)
                                      - (line.cash_credit or 0.0), 2)
    return rows


def test_an_approved_bonus_is_the_line_s_and_moved_not_spent_again(auth_headers, employee):
    from services.bonus_accounts import employee_bonus_account
    bonus = _approved_bonus(auth_headers, employee)
    run = _run(auth_headers)
    line = _line(run, employee)
    assert [b['bonus_id'] for b in line['breakdown']['bonuses']] == [bonus]
    assert line['net_salary'] == 9600.0, '8,100 and its 1,500 bonus'
    assert db.session.get(EmployeeBonus, bonus).payroll_id == line['id']
    assert _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)[0] == 200
    rows = _accrual(run['id'])
    payable = employee_bonus_account(db.session.get(Employee, employee))
    assert rows[payable.id] == 1500.0, 'his bonus payable, debited'
    assert sorted(v for v in rows.values() if v > 0) == [1500.0, 8100.0], 'the salary expense is the gross alone'


def test_a_bonus_in_a_run_is_not_paid_nor_reversed_alone(auth_headers, employee):
    bonus = _approved_bonus(auth_headers, employee)
    _run(auth_headers)
    code, body = _call('post', f'/api/bonuses/{bonus}/pay', auth_headers, {'payment_method': 'cash'})
    assert code == 409 and body.get('error') == 'in_payroll_run', body
    code, body = _call('post', f'/api/bonuses/{bonus}/reverse', auth_headers, {'reason': 'x'})
    assert code == 409 and body.get('code') == 'in_payroll_run', body


def test_the_line_s_voucher_pays_its_bonus(auth_headers, employee):
    bonus = _approved_bonus(auth_headers, employee)
    run = _run(auth_headers)
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    account = _call('get', '/api/payroll/payment-accounts', auth_headers)[1][0]['id']
    lines = [{'payroll_id': e['id'], 'payment_account_id': account} for e in run['entries']]
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/pay", auth_headers, {'lines': lines})
    assert code == 200, body
    paid = db.session.get(EmployeeBonus, bonus)
    assert paid.status == 'paid' and paid.payment_reference == _line(body, employee)['voucher']['voucher_number']


def test_a_draft_lets_a_bonus_go_and_a_cancelled_run_lets_them_all_go(auth_headers, employee):
    one = _approved_bonus(auth_headers, employee, 1500.0)
    two = _approved_bonus(auth_headers, employee, 500.0)
    run = _run(auth_headers)
    line = _line(run, employee)
    code, body = _call('put', f"/api/payroll/runs/{run['id']}/lines/{line['id']}", auth_headers, {'bonuses': [one]})
    assert code == 200 and _line(body, employee)['net_salary'] == 9600.0, body
    assert db.session.get(EmployeeBonus, two).payroll_id is None, 'let go: paid from a safe, or next month'
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    _call('post', f"/api/payroll/runs/{run['id']}/cancel", auth_headers)
    bonus = db.session.get(EmployeeBonus, one)
    assert (bonus.status, bonus.payroll_id) == ('approved', None)
    again = _line(_run(auth_headers), employee)
    assert {b['bonus_id'] for b in again['breakdown']['bonuses']} == {one, two}


def test_bonuses_the_books_do_not_owe_are_held_and_said_not_moved(auth_headers, employee):
    """مسعد on the 31 Oct copy: 2,512.50 approved, 0 owed in the books -- a voucher paid it."""
    from dual_system_helpers import create_dual_journal_entry
    from services.bonus_accounts import employee_bonus_account
    bonus = _approved_bonus(auth_headers, employee)
    payable = employee_bonus_account(db.session.get(Employee, employee))
    paid = JournalEntry(date=date(YEAR, 3, 31), description='صرف مكافأة بسند خارج شاشة المكافآت',
                        entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(paid)
    db.session.flush()
    from models import Account
    cash = Account(account_number=f'97{uuid.uuid4().int % 10**6:06d}', name='صندوق', type='Asset')
    db.session.add(cash)
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=paid.id, account_id=payable.id, cash_debit=1500.0)
    create_dual_journal_entry(journal_entry_id=paid.id, account_id=cash.id, cash_credit=1500.0)
    db.session.commit()
    line = _line(_run(auth_headers), employee)
    assert line['breakdown']['bonuses'] == [] and line['net_salary'] == 8100.0
    assert line['breakdown']['bonuses_held'] == {'approved_unpaid': 1500.0, 'owed_in_books': 0.0}
    assert db.session.get(EmployeeBonus, bonus).payroll_id is None


def _paid_outside(emp, amount):
    """A bonus paid by a voucher outside the bonus screen: his payable debited."""
    from dual_system_helpers import create_dual_journal_entry
    from models import Account
    from services.bonus_accounts import employee_bonus_account
    payable = employee_bonus_account(db.session.get(Employee, emp))
    paid = JournalEntry(date=date(YEAR, 3, 31), description='صرف مكافأة بقيد يدوي', entry_type='عادي',
                        is_posted=True, is_draft=False, created_by='t')
    cash = Account(account_number=f'97{uuid.uuid4().int % 10**6:06d}', name='صندوق', type='Asset')
    db.session.add_all([paid, cash])
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=paid.id, account_id=payable.id, cash_debit=amount)
    create_dual_journal_entry(journal_entry_id=paid.id, account_id=cash.id, cash_credit=amount)
    db.session.commit()


def test_several_bonuses_the_books_owe_in_part_are_paid_at_what_they_owe_newest_first(auth_headers, employee):
    """مبارك on the 2 Nov copy (the owner: «مكافأة أكتوبر تُصرف في مسير أكتوبر»):
    September's 2,912.50, 2,900 of it paid by a manual entry, and October's
    2,897.50 -- the books owe 2,910. Both were held. The books are shared out
    newest first: October's accrual stands whole; what was paid outside was
    the older's."""
    september = _approved_bonus(auth_headers, employee, 2912.5, month=9)
    _paid_outside(employee, 2900.0)
    october = _approved_bonus(auth_headers, employee, 2897.5, month=10)
    run = _run(auth_headers)
    line = _line(run, employee)
    shares = {row['bonus_id']: row['amount'] for row in line['breakdown']['bonuses']}
    assert shares == {october: 2897.5, september: 12.5}, 'what the books owe, newest first'
    assert 'bonuses_held' not in line['breakdown']
    assert line['breakdown']['bonus_books_cap'] == {'approved_unpaid': 5810.0, 'owed_in_books': 2910.0}
    assert line['net_salary'] == 8100.0 + 2910.0

    code, run = _call('put', f"/api/payroll/runs/{run['id']}/lines/{line['id']}", auth_headers,
                      {'bonuses': [september]})                # October's let go to a later month
    assert code == 200, run
    line = _line(run, employee)
    assert [(r['bonus_id'], r['amount']) for r in line['breakdown']['bonuses']] == [(september, 12.5)], \
        "September keeps its share -- not the books' whole"
    assert line['net_salary'] == 8112.5
    assert db.session.get(EmployeeBonus, october).payroll_id is None
    assert _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)[0] == 200

