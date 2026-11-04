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
                       {'name': f'موظف رواتب {uuid.uuid4().hex[:6]}', 'is_active': True})
    assert code in (200, 201), body
    return body['id']


def _payroll(headers, employee_id, month=3, year=2041, basic_salary=7000.0, status='pending'):
    """An entry made one by one before the runs (law 7: none is made now), as
    the books hold them -- approved through its route, so with its accrual."""
    entry = Payroll(employee_id=employee_id, month=month, year=year, basic_salary=basic_salary,
                    allowances=0.0, deductions=0.0, net_salary=basic_salary, status='pending', created_by='t')
    db.session.add(entry)
    db.session.commit()                                    # a savepoint under the fence
    if status == 'approved':
        code, body = _call('put', f'/api/payroll/{entry.id}', headers, {'status': 'approved'})
        return code, body
    return 201, entry.to_dict()


def _pay(headers, payroll_id):
    """Paid from the first cash or bank safe -- the test chart maps no default cash."""
    code, accounts = _call('get', '/api/payroll/payment-accounts', headers)
    return _call('post', f'/api/payroll/{payroll_id}/mark-paid', headers, {'payment_account_id': accounts[0]['id']})


def _accruals(payroll_id, kind='payroll_accrual'):
    return JournalEntry.query.filter_by(reference_type=kind, reference_id=payroll_id, is_deleted=False).count()


# ── 7: a month's salary is born in its run ─────────────────────────────────────

def test_a_month_s_salary_is_born_in_its_run_none_made_nor_cloned_beside_it(auth_headers):
    """HR-UX ط5 (2 Nov 2026): the run is the one way a month's salary is written."""
    emp = _employee(auth_headers)
    code, body = _call('post', '/api/payroll', auth_headers,
                       {'employee_id': emp, 'month': 3, 'year': 2041, 'basic_salary': 7000.0})
    assert (code, body.get('code')) == (409, 'payroll_is_the_run'), body
    old = _payroll(auth_headers, emp)[1]['id']
    code, body = _call('post', f'/api/payroll/{old}/clone', auth_headers, {'month': 4, 'year': 2041})
    assert (code, body.get('code')) == (409, 'payroll_is_the_run'), body
    assert Payroll.query.filter_by(employee_id=emp).count() == 1


def test_an_entry_approved_is_approved_with_its_accrual_its_net_the_server_s(auth_headers):
    code, body = _payroll(auth_headers, _employee(auth_headers), status='approved')
    assert code == 200 and body['status'] == 'approved', body
    assert body['net_salary'] == 7000.0 and _accruals(body['id']) == 1


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
    assert _call('post', '/api/payroll/runs', auth_headers, {'month': 12, 'year': 202})[0] == 400
    assert _call('post', '/api/payroll/runs', auth_headers, {'month': 13, 'year': 2041})[0] == 400
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


def test_an_entry_s_accrual_and_its_reversal_are_dated_its_month_s_last_day(auth_headers):
    """REPORTS ت6-2أ (the owner, 4 Nov 2026: «آخر يوم في شهره»): on the 2 Nov
    copy June's salaries were accrued on 5 July, July's on 5 August, August's
    on 2 September, September's on 4 October -- each month's income statement
    carried the month before's."""
    from datetime import date
    entry = _payroll(auth_headers, _employee(auth_headers), month=6, status='approved')[1]['id']
    accrual = JournalEntry.query.filter_by(reference_type='payroll_accrual', reference_id=entry).one()
    assert accrual.date.date() == date(2041, 6, 30), accrual.date
    _call('put', f'/api/payroll/{entry}', auth_headers, {'status': 'cancelled'})
    reversal = JournalEntry.query.filter_by(reference_type='payroll_accrual_reversal', reference_id=entry).one()
    assert reversal.date == accrual.date


def test_an_entry_s_accrual_dated_its_approval_is_put_on_its_month_s_last_day(auth_headers):
    """services/repair/payroll_accrual_dates reaches the salaries accrued one by one too."""
    from datetime import date, datetime
    from services.repair.payroll_accrual_dates import redate_accruals
    entry = _payroll(auth_headers, _employee(auth_headers), month=7, status='approved')[1]['id']
    accrual = JournalEntry.query.filter_by(reference_type='payroll_accrual', reference_id=entry).one()
    accrual.date = datetime(2041, 8, 5, 9, 0)                           # as before the law
    db.session.flush()
    assert any(r.get('payroll_id') == entry for r in redate_accruals(by='t')['redated'])
    redate_accruals(by='t', dry_run=False)
    assert accrual.date.date() == date(2041, 7, 31)
