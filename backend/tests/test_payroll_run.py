"""A month's payroll, one document: drafted, reviewed, approved with one accrual, paid in a batch (PAYROLL-2, M2b).

The owner, 1 Nov 2026 («اودع وابدأ»). On the 31 Oct copy each month was five
entries keyed by hand, approved and paid one by one, their figures not the
employee file's. The run:

  1. is drafted from the salary structures, prorated by the policy's divisor
     for a month joined or left; each employee left out is said, with why;
  2. is reviewed while a draft: additions and deductions, each with its reason;
  3. is approved with ONE accrual, or stays a draft; its policy frozen on it;
  4. is cancelled whole -- an approved one's accrual reversed, a month
     drafted again; one with a paid line is not cancelled;
  5. is paid in a batch by how each employee is paid, all or none.

One regular run a month; its lines are the run's alone.

Run:
    python -m pytest tests/test_payroll_run.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import JournalEntry, JournalEntryLine, Payroll, PayrollRun, db

POLICY = {'housing_ratio': 0.25, 'transport_ratio': 0.10, 'advance_cap_ratio': 0.10,
          'advance_installments': 3, 'attendance_enabled': False, 'day_divisor': 30,
          'overtime_premium_ratio': 0.5, 'eos_wage_base': 'gross', 'eos_first_years': 5,
          'eos_first_years_months': 0.5, 'eos_after_years_months': 1.0}
MONTH, YEAR = 4, 2041              # April: thirty days


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


@pytest.fixture
def staff(auth_headers):
    """Two employees with structures, one joined on the 16th, one with none.
    One with a hire date has his end-of-service provision booked: its expense mapped."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    from models import Account, AccountingMapping
    assert _call('put', '/api/payroll/policy', auth_headers, POLICY)[0] == 200
    if not AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                             account_type='eos_expense').first():
        expense = Account(account_number=f'98{uuid.uuid4().int % 10**8:08d}', name='مصروف نهاية الخدمة',
                          type='Expense')
        db.session.add(expense)
        db.session.flush()
        db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='eos_expense',
                                         account_id=expense.id, is_active=True))
        db.session.commit()
    made = {}
    for key, fields, structure in (
            ('full', {}, {'basic': 6000, 'housing': 1500, 'transport': 600}),
            ('joined', {'hire_date': f'{YEAR}-{MONTH:02d}-16'}, {'basic': 4000, 'housing': 1000, 'transport': 400}),
            ('bare', {}, None)):
        code, body = _call('post', '/api/employees', auth_headers,
                           {'name': f'موظف مسير {key} {uuid.uuid4().hex[:6]}', 'is_active': True, **fields})
        assert code in (200, 201), body
        made[key] = body['id']
        if structure:
            code, body = _call('post', f"/api/employees/{body['id']}/salary-structures", auth_headers,
                               {'effective_from': f'{YEAR}-01-01', **structure})
            assert code == 201, body
    return made


def _run(headers, month=MONTH, year=YEAR):
    return _call('post', '/api/payroll/runs', headers, {'month': month, 'year': year})


def _line(run, employee_id):
    return next(e for e in run['entries'] if e['employee_id'] == employee_id)


def _accruals(run_id, kind='payroll_run_accrual'):
    return JournalEntry.query.filter_by(reference_type=kind, reference_id=run_id, is_deleted=False).all()


def _accounts(headers):
    return _call('get', '/api/payroll/payment-accounts', headers)[1]


# ── 1. drafted from the structures ─────────────────────────────────────────────

def test_a_run_is_drafted_from_the_structures_and_says_who_is_left_out(auth_headers, staff):
    code, run = _run(auth_headers)
    assert code == 201 and run['status'] == 'draft', run
    full = _line(run, staff['full'])
    assert (full['basic_salary'], full['allowances'], full['net_salary']) == (6000.0, 2100.0, 8100.0)
    assert full['breakdown']['monthly']['housing'] == 1500.0 and full['breakdown']['whole_month']
    joined = _line(run, staff['joined'])
    assert (joined['breakdown']['days'], joined['net_salary']) == (15, 2700.0), 'half of 5,400: 15 of 30 days'
    left = {row['employee_id']: row['reason'] for row in run['left_out']}
    assert left.get(staff['bare']) == 'no_structure', 'said, not dropped silently'


def test_one_regular_run_a_month_and_its_month_is_the_run_s(auth_headers, staff):
    run = _run(auth_headers)[1]
    assert _run(auth_headers)[0] == 409
    code, body = _call('post', '/api/payroll', auth_headers,
                       {'employee_id': staff['bare'], 'month': MONTH, 'year': YEAR, 'basic_salary': 5000.0})
    assert code == 409, 'an employee is added from the run, not beside it'
    assert _call('get', f"/api/payroll/runs/{run['id']}", auth_headers)[0] == 200


def test_an_employee_with_an_entry_of_his_own_for_the_month_is_left_out_and_said(auth_headers, staff):
    db.session.add(Payroll(employee_id=staff['full'], month=MONTH, year=YEAR, basic_salary=6000.0,
                           net_salary=6000.0, status='paid', created_by='t'))   # one made before the runs
    db.session.commit()
    run = _run(auth_headers)[1]
    assert {r['employee_id']: r['reason'] for r in run['left_out']}[staff['full']] == 'has_an_entry'


def test_one_put_right_is_added_to_the_draft_and_the_reviewed_lines_stay(auth_headers, staff):
    """HR-UX ط1 (2 Nov 2026): adding one meant cancelling the draft, every
    line's additions and deductions lost."""
    run = _run(auth_headers)[1]
    full = _line(run, staff['full'])
    url = f"/api/payroll/runs/{run['id']}/lines"
    code, run = _call('put', f"{url}/{full['id']}", auth_headers,
                      {'additions': [{'label': 'إضافي', 'amount': 300}]})
    assert code == 200, run
    code, body = _call('post', url, auth_headers, {'employee_id': staff['bare']})
    assert (code, body.get('code')) == (409, 'payroll_line_not_eligible') and 'هيكل' in body['error'], body
    _call('post', f"/api/employees/{staff['bare']}/salary-structures", auth_headers,
          {'effective_from': f'{YEAR}-{MONTH:02d}-01', 'basic': 5000})
    code, run = _call('post', url, auth_headers, {'employee_id': staff['bare']})
    assert code == 200, run
    assert _line(run, staff['bare'])['net_salary'] == 5000.0
    assert _line(run, staff['full'])['net_salary'] == 8400.0, 'its addition kept'
    assert staff['bare'] not in {r['employee_id'] for r in run['left_out']}
    assert _call('post', url, auth_headers, {'employee_id': staff['bare']})[0] == 409, 'one line each'
    removed = _line(run, staff['joined'])
    run = _call('delete', f"{url}/{removed['id']}", auth_headers)[1]
    code, run = _call('post', url, auth_headers, {'employee_id': staff['joined']})
    assert code == 200 and _line(run, staff['joined'])['net_salary'] == 2700.0, 'removed, wanted back'
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    code, body = _call('post', url, auth_headers, {'employee_id': staff['joined']})
    assert code == 409, 'an approved run takes no line'


def test_a_run_is_previewed_by_its_rules_and_nothing_is_kept(auth_headers, staff):
    """HR-UX ط4 (2 Nov 2026): who is in, who is left out and why, and who
    would stop the batch pay -- before the draft is made."""
    url = f'/api/payroll/runs/preview?month={MONTH}&year={YEAR}'
    code, seen = _call('get', url, auth_headers)
    assert code == 200, seen
    assert seen['id'] is None and PayrollRun.query.filter_by(month=MONTH, year=YEAR).count() == 0, 'nothing kept'
    assert {e['employee_id']: e['net_salary'] for e in seen['entries']}[staff['joined']] == 2700.0
    assert {r['employee_id']: r['reason'] for r in seen['left_out']}[staff['bare']] == 'no_structure'
    assert {r['employee_id'] for r in seen['will_not_pay']} >= {staff['full'], staff['joined']}, 'no way to be paid'
    code, run = _run(auth_headers)
    assert code == 201, 'the month is still to draft'
    assert ({e['employee_id']: e['net_salary'] for e in run['entries']}
            == {e['employee_id']: e['net_salary'] for e in seen['entries']}), 'the same rules, the same lines'
    assert _call('get', url, auth_headers)[0] == 409, 'a month with a run is opened, not previewed'


def test_the_months_to_draft_offer_the_first_without_a_run(auth_headers, staff):
    from datetime import date
    from services.payroll_run import months_to_draft
    _run(auth_headers, month=4, year=2043)
    said = months_to_draft(date(2043, 6, 2))
    rows = {(r['year'], r['month']): r['state'] for r in said['months']}
    assert rows == {(2043, 4): 'draft', (2043, 5): 'open', (2043, 6): 'open'}
    assert said['suggested'] == {'month': 5, 'year': 2043}, 'May, not this June'


# ── 2. reviewed while a draft ──────────────────────────────────────────────────

def test_a_draft_s_line_takes_additions_and_deductions_each_with_its_reason(auth_headers, staff):
    run = _run(auth_headers)[1]
    line = _line(run, staff['full'])
    url = f"/api/payroll/runs/{run['id']}/lines/{line['id']}"
    code, body = _call('put', url, auth_headers, {'additions': [{'label': 'عمل إضافي', 'amount': 300}],
                                                  'deductions': [{'label': 'غياب يوم', 'amount': 200}]})
    assert code == 200, body
    assert _line(body, staff['full'])['net_salary'] == 8200.0
    assert _call('put', url, auth_headers, {'deductions': [{'label': '', 'amount': 50}]})[0] == 409, 'a reason'
    assert _call('put', f"/api/payroll/{line['id']}", auth_headers, {'basic_salary': 1.0})[0] == 409, \
        'a line of the run is edited in the run'


# ── 3. approved with one accrual ───────────────────────────────────────────────

def test_a_run_is_approved_with_one_accrual_and_its_policy_frozen(auth_headers, staff):
    run = _run(auth_headers)[1]
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    assert code == 200 and body['status'] == 'approved', body
    assert {e['status'] for e in body['entries']} == {'approved'}
    accruals = _accruals(run['id'])
    assert len(accruals) == 1, 'one entry for the month, not one an employee'
    lines = JournalEntryLine.query.filter_by(journal_entry_id=accruals[0].id).all()
    eos = round(sum(e['breakdown']['eos'].get('provision', 0.0) for e in body['entries']), 2)
    assert eos > 0, 'the one joined on the 16th has his 15 days provisioned'
    assert round(sum(l.cash_debit or 0.0 for l in lines), 2) == round(sum(l.cash_credit or 0.0 for l in lines), 2) \
        == round(body['totals']['net_salary'] + eos, 2)
    assert body['totals']['net_salary'] == 10800.0
    assert db.session.get(PayrollRun, run['id']).policy_snapshot
    line = _line(body, staff['full'])
    assert _call('put', f"/api/payroll/runs/{run['id']}/lines/{line['id']}", auth_headers,
                 {'deductions': [{'label': 'x', 'amount': 1}]})[0] == 409, 'approved is kept'
    assert _call('put', f"/api/payroll/{line['id']}", auth_headers, {'status': 'cancelled'})[0] == 409, \
        'a line is not cancelled alone'


def test_a_run_whose_line_is_nothing_stays_a_draft(auth_headers, staff):
    run = _run(auth_headers)[1]
    line = _line(run, staff['joined'])
    _call('put', f"/api/payroll/runs/{run['id']}/lines/{line['id']}", auth_headers,
          {'deductions': [{'label': 'غياب', 'amount': line['net_salary']}]})
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    assert code == 409 and db.session.get(PayrollRun, run['id']).status == 'draft', body
    assert _accruals(run['id']) == []


# ── 4. cancelled whole ─────────────────────────────────────────────────────────

def test_an_approved_run_cancelled_reverses_its_accrual_and_its_month_is_drafted_again(auth_headers, staff):
    run = _run(auth_headers)[1]
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/cancel", auth_headers)
    assert code == 200 and body['status'] == 'cancelled', body
    assert len(_accruals(run['id'], 'payroll_run_accrual_reversal')) == 1
    assert {e['status'] for e in body['entries']} == {'cancelled'}
    assert _run(auth_headers)[0] == 201, 'a cancelled run holds no month'


# ── 5. paid in a batch ─────────────────────────────────────────────────────────

def test_a_run_is_paid_by_how_each_employee_is_paid_all_or_none(auth_headers, staff):
    run = _run(auth_headers)[1]
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    account = _accounts(auth_headers)[0]['id']
    pay = f"/api/payroll/runs/{run['id']}/pay"
    _call('put', f"/api/employees/{staff['full']}", auth_headers, {'payment_method': 'bank'})
    code, body = _call('post', pay, auth_headers, {'bank_account_id': account})
    assert code == 409 and 'لم يُحدَّد' in body['error'], body
    assert Payroll.query.filter_by(payroll_run_id=run['id'], status='paid').count() == 0, 'none, not some'
    _call('put', f"/api/employees/{staff['joined']}", auth_headers, {'payment_method': 'cash'})
    code, body = _call('post', pay, auth_headers, {'bank_account_id': account, 'cash_account_id': account})
    assert code == 200 and body['status'] == 'paid', body
    assert all(e['status'] == 'paid' and e['voucher_id'] for e in body['entries'])
    assert _call('post', f"/api/payroll/runs/{run['id']}/cancel", auth_headers)[0] == 409, 'paid is not cancelled'
    code, slip = _call('get', f"/api/payroll/{_line(body, staff['joined'])['id']}/payslip", auth_headers)
    assert code == 200 and slip['breakdown']['days'] == 15 and slip['entry']['voucher_id'], slip


def test_a_line_may_be_paid_from_its_own_account_with_its_advance_deducted(auth_headers, staff):
    run = _run(auth_headers)[1]
    _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    account = _accounts(auth_headers)[0]['id']
    lines = [{'payroll_id': e['id'], 'payment_account_id': account} for e in run['entries']]
    lines[0]['advance_deduction_amount'] = 999999
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/pay", auth_headers, {'lines': lines})
    assert code == 409, 'more than the net'
    assert Payroll.query.filter_by(payroll_run_id=run['id'], status='paid').count() == 0
    lines[0]['advance_deduction_amount'] = 100
    assert _call('post', f"/api/payroll/runs/{run['id']}/pay", auth_headers, {'lines': lines})[0] == 200
