"""A payment voucher cancelled reopens what it paid; the bonuses' statuses put right by the books (PAYROLL-4).

The owner, 1 Nov 2026: «الصحيح هو ما في الدفاتر». On the 31 Oct copy يوسف's
bonuses #19 and #51 said «paid» though BPAY-19 and BPAY-51 were cancelled on 6
Aug -- the cancellation never reopened a bonus -- and a salary's voucher
cancelled left its entry paid. مسعد's #52 said «approved» though a manual entry
paid it. The cancellation reopens the document now; the tool puts the old ones
right, by the books and nothing else.

Run:
    python -m pytest tests/test_voucher_cancel_reopens_its_document.py -v
"""
import uuid
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from models import Account, Employee, EmployeeBonus, JournalEntry, Payroll, PayrollRun, Voucher, db

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


@pytest.fixture
def employee(auth_headers):
    assert _call('put', '/api/payroll/policy', auth_headers, POLICY)[0] == 200
    code, body = _call('post', '/api/employees', auth_headers,
                       {'name': f'موظف سند {uuid.uuid4().hex[:6]}', 'is_active': True})
    assert code in (200, 201), body
    emp = body['id']
    assert _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
                 {'effective_from': f'{YEAR}-01-01', 'basic': 6000, 'housing': 1500, 'transport': 600})[0] == 201
    return emp


def _approved_bonus(headers, emp, amount):
    bonus = EmployeeBonus(employee_id=emp, bonus_type='fixed', amount=amount, status='pending',
                          period_start=date(YEAR, 3, 1), period_end=date(YEAR, 3, 31))
    db.session.add(bonus)
    db.session.commit()
    assert _call('post', f'/api/bonuses/{bonus.id}/approve', headers, {})[0] == 200
    return bonus


def _book(employee_id, amount):
    """Paid from the bonus account outside the bonus screen (a manual entry)."""
    from dual_system_helpers import create_dual_journal_entry
    from services.bonus_accounts import employee_bonus_account
    payable = employee_bonus_account(db.session.get(Employee, employee_id))
    cash = Account(account_number=f'97{uuid.uuid4().int % 10**6:06d}', name='صندوق', type='Asset')
    entry = JournalEntry(date=datetime(YEAR, 3, 31), description='صرف مكافأة بقيد يدوي', entry_type='عادي',
                         is_posted=True, is_draft=False, created_by='t')
    db.session.add_all([cash, entry])
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=payable.id, cash_debit=amount)
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=cash.id, cash_credit=amount)
    db.session.commit()


def _paid_by_a_cancelled_voucher(bonus):
    """As BPAY-19 was: the bonus marked paid, its payment voucher cancelled."""
    db.session.add(Voucher(voucher_number=f'BPAY-{bonus.id}', voucher_type='payment', date=date(YEAR, 3, 31),
                           status='cancelled', reference_type='bonus', reference_id=bonus.id, created_by='t'))
    bonus.status = 'paid'
    db.session.commit()


# ── the cancellation reopens what it paid ──────────────────────────────────────

def test_a_bonus_s_payment_voucher_cancelled_reopens_the_bonus(auth_headers, employee):
    from services.voucher_cancel_documents import reopen
    bonus = _approved_bonus(auth_headers, employee, 1500.0)
    bonus.status, bonus.payment_reference = 'paid', f'BPAY-{bonus.id}'
    voucher = Voucher(voucher_number=f'BPAY-{bonus.id}', voucher_type='payment', date=date(YEAR, 3, 31),
                      status='cancelled', reference_type='bonus', reference_id=bonus.id, created_by='t')
    db.session.add(voucher)
    db.session.flush()
    reopen(voucher)
    assert (bonus.status, bonus.payment_reference) == ('approved', None)


def test_a_salary_s_voucher_cancelled_reopens_its_line_its_bonus_and_its_run(auth_headers, employee):
    bonus = _approved_bonus(auth_headers, employee, 1500.0)
    code, run = _call('post', '/api/payroll/runs', auth_headers, {'month': MONTH, 'year': YEAR})
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    account = _call('get', '/api/payroll/payment-accounts', auth_headers)[1][0]['id']
    lines = [{'payroll_id': e['id'], 'payment_account_id': account} for e in run['entries']]
    assert _call('post', f"/api/payroll/runs/{run['id']}/pay", auth_headers, {'lines': lines})[0] == 200
    line = Payroll.query.filter_by(payroll_run_id=run['id'], employee_id=employee).one()
    code, body = _call('post', f'/api/vouchers/{line.voucher_id}/cancel', auth_headers, {'reason': 'خطأ'})
    assert code == 200, body
    db.session.expire_all()
    line = Payroll.query.filter_by(payroll_run_id=run['id'], employee_id=employee).one()
    assert (line.status, line.voucher_id) == ('approved', None), 'paid again from the run'
    assert db.session.get(EmployeeBonus, bonus.id).status == 'approved'
    assert db.session.get(PayrollRun, run['id']).status == 'approved'


# ── the tool: the old ones put right by the books ──────────────────────────────

def test_the_tool_reopens_the_one_set_the_books_still_owe(auth_headers, employee):
    """يوسف: #11 paid otherwise, #19 and #51 owed -- their vouchers cancelled."""
    from services.repair.bonus_status_from_books import settle
    eleven = _approved_bonus(auth_headers, employee, 3710.0)
    _book(employee, 3710.0)                                  # #11 paid by manual vouchers
    nineteen = _approved_bonus(auth_headers, employee, 3037.5)
    fifty_one = _approved_bonus(auth_headers, employee, 3402.5)
    for bonus in (eleven, nineteen, fifty_one):
        _paid_by_a_cancelled_voucher(bonus)
    plan = settle(by='t', now=datetime(2041, 4, 1))
    assert {r['bonus_id'] for r in plan['reopened']} == {nineteen.id, fifty_one.id}
    assert db.session.get(EmployeeBonus, nineteen.id).status == 'paid', 'a dry run writes nothing'
    settle(by='المالك', now=datetime(2041, 4, 1), dry_run=False)
    assert [db.session.get(EmployeeBonus, b.id).status for b in (eleven, nineteen, fifty_one)] == \
        ['paid', 'approved', 'approved']


def test_the_tool_pays_in_the_books_what_they_owe_nothing_of(auth_headers, employee):
    """مسعد #52: approved, paid by a manual entry."""
    from services.repair.bonus_status_from_books import BOOKS_REFERENCE, settle
    bonus = _approved_bonus(auth_headers, employee, 2512.5)
    _book(employee, 2512.5)
    settle(by='المالك', now=datetime(2041, 4, 1), dry_run=False)
    settled = db.session.get(EmployeeBonus, bonus.id)
    assert (settled.status, settled.payment_reference) == ('paid', BOOKS_REFERENCE)


def test_one_bonus_the_books_owe_in_part_is_paid_by_the_run_at_what_they_owe(auth_headers, employee):
    """مبارك #55: 2,912.50 approved, 2,900 paid outside, 12.50 owed."""
    from services.repair.bonus_status_from_books import settle
    bonus = _approved_bonus(auth_headers, employee, 2912.5)
    _book(employee, 2900.0)
    plan = settle(by='t', now=datetime(2041, 4, 1), dry_run=False)
    assert plan['paid_in_books'] == [] and db.session.get(EmployeeBonus, bonus.id).status == 'approved'
    code, run = _call('post', '/api/payroll/runs', auth_headers, {'month': MONTH, 'year': YEAR})
    line = next(e for e in run['entries'] if e['employee_id'] == employee)
    assert [b['amount'] for b in line['breakdown']['bonuses']] == [12.5]
    assert line['breakdown']['bonus_books_cap'] == {'approved_unpaid': 2912.5, 'owed_in_books': 12.5}
    assert line['net_salary'] == 8112.5
