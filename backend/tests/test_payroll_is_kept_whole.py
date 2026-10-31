"""A month's salary is kept whole: approved with its accrual, paid by its voucher (PAYROLL-1).

The owner, 1 Nov 2026 («ابدأ» to the payroll plan's first stage). Measured on
the 31 Oct copy: fifteen salaries of December-February (122,500) were «paid»
with no accrual -- the form's status list offered «مدفوع» -- and the code let
more slip: amounts edited after the entry was posted, a bulk approval that
kept «approved» when its accrual failed, a cancellation that left its posted
accrual standing. Six laws:

  1. the amounts, the employee and the month are edited while pending alone;
  2. «paid» is set by the payment that writes its voucher, nothing else;
  3. the net is the server's: basic + allowances - deductions;
  4. approving is its accrual: when the accrual cannot be written the entry
     stays pending, one or many;
  5. only an approved entry is paid, its accrual written first if a legacy
     one has none;
  6. cancelling an approved entry reverses its accrual; a paid one is not
     cancelled; only a pending one with no entry is deleted.

Run:
    python -m pytest tests/test_payroll_is_kept_whole.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import JournalEntry, Payroll, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def _employee(headers):
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'موظف رواتب {uuid.uuid4().hex[:6]}', 'salary': 7000.0, 'is_active': True})
    assert code in (200, 201), body
    return body['id']


def _payroll(headers, employee_id, **fields):
    body = {'employee_id': employee_id, 'month': 3, 'year': 2041, 'basic_salary': 7000.0, **fields}
    return _call('post', '/api/payroll', headers, body)


def _pay(headers, payroll_id):
    """Paid from the first cash or bank safe -- the test chart maps no default cash."""
    code, accounts = _call('get', '/api/payroll/payment-accounts', headers)
    return _call('post', f'/api/payroll/{payroll_id}/mark-paid', headers, {'payment_account_id': accounts[0]['id']})


def _accruals(payroll_id, kind='payroll_accrual'):
    return JournalEntry.query.filter_by(reference_type=kind, reference_id=payroll_id, is_deleted=False).count()


# ── 2 and 3: a new entry is pending, its net the server's ───────────────────────

def test_a_new_entry_is_pending_and_its_net_the_server_s(auth_headers):
    emp = _employee(auth_headers)
    code, body = _payroll(auth_headers, emp, allowances=500.0, deductions=200.0, net_salary=99999.0)
    assert code == 201, body
    assert (body['status'], body['net_salary']) == ('pending', 7300.0), 'basic + allowances - deductions'
    code, body = _payroll(auth_headers, emp, month=4, status='paid')
    assert code == 400 and 'صرف' in body['error'], 'paid is the payment\'s to say'


def test_a_new_entry_made_approved_is_approved_with_its_accrual(auth_headers):
    code, body = _payroll(auth_headers, _employee(auth_headers), status='approved')
    assert code == 201 and body['status'] == 'approved', body
    assert _accruals(body['id']) == 1


# ── 1: amounts are kept once approved ──────────────────────────────────────────

def test_the_amounts_are_kept_once_approved(auth_headers):
    code, body = _payroll(auth_headers, _employee(auth_headers))
    pid = body['id']
    code, body = _call('put', f'/api/payroll/{pid}', auth_headers, {'status': 'approved'})
    assert code == 200 and _accruals(pid) == 1, body
    code, body = _call('put', f'/api/payroll/{pid}', auth_headers, {'basic_salary': 9000.0})
    assert code == 409, 'its accrual says 7,000'
    assert db.session.get(Payroll, pid).basic_salary == 7000.0
    assert _call('put', f'/api/payroll/{pid}', auth_headers, {'notes': 'ملاحظة'})[0] == 200, 'a note is not an amount'


# ── 2 and 5: paid by the payment alone, an approved one ────────────────────────

def test_paid_is_the_payment_s_and_only_an_approved_entry_is_paid(auth_headers):
    code, body = _payroll(auth_headers, _employee(auth_headers))
    pid = body['id']
    assert _call('put', f'/api/payroll/{pid}', auth_headers, {'status': 'paid'})[0] == 409
    code, body = _pay(auth_headers, pid)
    assert code == 409 and 'اعتمد' in body['error'], 'a pending entry is approved first'
    _call('put', f'/api/payroll/{pid}', auth_headers, {'status': 'approved'})
    code, body = _pay(auth_headers, pid)
    assert code == 200 and body['status'] == 'paid' and body['voucher_id'], body


def test_a_legacy_approved_entry_without_its_accrual_has_it_written_before_it_is_paid(auth_headers):
    code, body = _payroll(auth_headers, _employee(auth_headers))
    pid = body['id']
    db.session.get(Payroll, pid).status = 'approved'          # as December-February were left
    db.session.flush()
    assert _accruals(pid) == 0
    code, body = _pay(auth_headers, pid)
    assert code == 200, body
    assert _accruals(pid) == 1, 'the expense is in the books before the money leaves'


# ── 4: approving is its accrual ────────────────────────────────────────────────

def test_an_approval_whose_accrual_fails_stays_pending(auth_headers):
    emp = _employee(auth_headers)
    code, body = _payroll(auth_headers, emp, basic_salary=0.0)        # nothing to accrue
    pid = body['id']
    code, body = _call('put', f'/api/payroll/{pid}', auth_headers, {'status': 'approved'})
    assert code == 409 and db.session.get(Payroll, pid).status == 'pending', body
    code, body = _call('post', '/api/payroll/bulk-approve', auth_headers, {'ids': [pid]})
    assert body['approved'] == 0 and body['skipped'] == 1
    db.session.expire_all()
    assert db.session.get(Payroll, pid).status == 'pending', 'it said approved with no accrual'


# ── 6: cancelling reverses; paid is not cancelled; pending alone is deleted ───

def test_cancelling_an_approved_entry_reverses_its_accrual(auth_headers):
    emp = _employee(auth_headers)
    one = _payroll(auth_headers, emp, status='approved')[1]['id']
    two = _payroll(auth_headers, emp, month=4, status='approved')[1]['id']
    assert _call('delete', f'/api/payroll/{one}', auth_headers)[0] == 409, 'its accrual is posted'
    assert _call('put', f'/api/payroll/{one}', auth_headers, {'status': 'cancelled'})[0] == 200
    assert _accruals(one, 'payroll_accrual_reversal') == 1
    code, body = _call('post', '/api/payroll/bulk-cancel', auth_headers, {'ids': [two]})
    assert body['cancelled'] == 1 and _accruals(two, 'payroll_accrual_reversal') == 1, body


def test_a_paid_entry_is_not_cancelled(auth_headers):
    pid = _payroll(auth_headers, _employee(auth_headers), status='approved')[1]['id']
    assert _pay(auth_headers, pid)[0] == 200
    assert _call('put', f'/api/payroll/{pid}', auth_headers, {'status': 'cancelled'})[0] == 409
    assert db.session.get(Payroll, pid).status == 'paid'


def test_a_month_is_1_to_12_of_a_four_digit_year(auth_headers):
    """The 31 Oct copy held a pending entry for December of «202»."""
    emp = _employee(auth_headers)
    assert _payroll(auth_headers, emp, year=202)[0] == 400
    assert _payroll(auth_headers, emp, month=13)[0] == 400
    pid = _payroll(auth_headers, emp)[1]['id']
    assert _call('put', f'/api/payroll/{pid}', auth_headers, {'year': 202})[0] in (400, 409)


def test_a_saved_stray_month_is_removed_by_its_tool_and_nothing_else(auth_headers):
    """م0: #3 on the 31 Oct copy -- December of «202», pending, nothing written for it."""
    from services.repair.payroll_stray_periods import remove_stray_periods
    emp = _employee(auth_headers)
    stray = Payroll(employee_id=emp, month=12, year=202, basic_salary=10000.0, net_salary=10000.0, status='pending')
    good = Payroll(employee_id=emp, month=12, year=2040, basic_salary=10000.0, net_salary=10000.0, status='pending')
    db.session.add_all([stray, good])
    db.session.flush()
    plan = remove_stray_periods(by='t')                              # dry run
    assert stray.id in [r['id'] for r in plan['removed']] and db.session.get(Payroll, stray.id) is not None
    remove_stray_periods(by='المالك', dry_run=False)
    assert db.session.get(Payroll, stray.id) is None
    assert db.session.get(Payroll, good.id) is not None
