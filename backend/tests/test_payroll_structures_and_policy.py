"""The payroll's data and policy: structures, schemes, payment, ratios as data (PAYROLL-2).

The owner, 1 Nov 2026 («اودع ثم أكمل», his seven decisions):
  - a salary is a structure from a day on -- basic, housing, transport,
    other; the employee file says the one in force; a structure a salary was
    approved by is not changed -- the past keeps what it was paid by;
  - contributions are schemes, not nationalities («الفكرة أعم»), each rate a
    dated component on its base, capped;
  - each employee is paid by bank (a checked IBAN) or cash;
  - every ratio is data («النسب ... قابلة للتعديل»): not set is refused, and
    no rate is written in the payroll's code (the guard below).

Run:
    python -m pytest tests/test_payroll_structures_and_policy.py -v
"""
import ast
import uuid
from pathlib import Path

import pytest
from flask import g

from app import app as flask_app
from models import Employee, Settings, db

POLICY = {'housing_ratio': 0.25, 'transport_ratio': 0.10, 'advance_cap_ratio': 0.10,
          'advance_installments': 3, 'attendance_enabled': False, 'day_divisor': 30,
          'overtime_premium_ratio': 0.5, 'eos_wage_base': 'gross', 'eos_first_years': 5,
          'eos_first_years_months': 0.5, 'eos_after_years_months': 1.0}


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(method, url, headers, body=None):
    g.pop('current_user', None)
    resp = getattr(flask_app.test_client(), method)(url, headers=headers, json=body)
    return resp.status_code, (resp.get_json() or {})


def _employee(headers, **fields):
    code, body = _call('post', '/api/employees', headers,
                       {'name': f'موظف هيكل {uuid.uuid4().hex[:6]}', 'is_active': True, **fields})
    return code, body


def _policy(headers, **changes):
    return _call('put', '/api/payroll/policy', headers, {**POLICY, **changes})


# ── the policy is data ─────────────────────────────────────────────────────────

def test_a_policy_not_set_is_refused_not_guessed(auth_headers):
    Settings.query.first().payroll_policy = None
    db.session.flush()
    code, body = _call('get', '/api/payroll/structure-suggestion?gross=10000', auth_headers)
    assert code == 400 and body.get('code') == 'payroll_policy_not_set', body


def test_a_gross_is_split_by_the_owner_s_ratios_and_kept_whole(auth_headers):
    assert _policy(auth_headers)[0] == 200
    code, body = _call('get', '/api/payroll/structure-suggestion?gross=10000', auth_headers)
    assert code == 200, body
    assert (body['basic'], body['housing'], body['transport']) == (7407.41, 1851.85, 740.74)
    assert round(body['basic'] + body['housing'] + body['transport'], 2) == 10000.0
    _policy(auth_headers, housing_ratio=0.0, transport_ratio=0.0)        # his to change
    assert _call('get', '/api/payroll/structure-suggestion?gross=10000', auth_headers)[1]['basic'] == 10000.0


def test_the_policy_is_checked_as_it_is_edited(auth_headers):
    _policy(auth_headers)
    assert _policy(auth_headers, housing_ratio=1.5)[0] == 400, 'a ratio is 0..1'
    assert _policy(auth_headers, advance_installments=2.5)[0] == 400, 'a count is whole'
    assert _policy(auth_headers, day_divisor=40)[0] == 400
    assert _call('put', '/api/payroll/policy', auth_headers, {'vat': 0.15})[0] == 400, 'no key of its own'
    assert _call('get', '/api/payroll/policy', auth_headers)[1]['policy'] == POLICY, 'a refused edit keeps it'


# ── salary structures ──────────────────────────────────────────────────────────

def test_a_structure_is_dated_and_the_file_says_the_one_in_force(auth_headers):
    emp = _employee(auth_headers)[1]['id']
    url = f'/api/employees/{emp}/salary-structures'
    code, body = _call('post', url, auth_headers, {'effective_from': '2026-01-01', 'basic': 6000,
                                                   'housing': 1500, 'transport': 600})
    assert code == 201 and body['gross'] == 8100.0, body
    assert db.session.get(Employee, emp).salary == 8100.0, 'the file and the payroll say one thing'
    assert _call('post', url, auth_headers, {'effective_from': '2026-01-01', 'basic': 7000})[0] == 400
    _call('post', url, auth_headers, {'effective_from': '2099-01-01', 'basic': 9000})
    body = _call('get', url, auth_headers)[1]
    assert len(body['structures']) == 2
    assert db.session.get(Employee, emp).salary == 8100.0, 'a future structure is not in force yet'
    assert _call('post', url, auth_headers, {'effective_from': '2026-02-01', 'basic': -1})[0] == 400


def test_a_structure_a_salary_was_approved_by_is_kept(auth_headers):
    emp = _employee(auth_headers)[1]['id']
    structure = _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
                      {'effective_from': '2041-01-01', 'basic': 7000})[1]['id']
    assert _call('put', f'/api/salary-structures/{structure}', auth_headers, {'basic': 7100})[0] == 200, \
        'nothing was approved by it yet'
    listed = lambda: _call('get', f'/api/employees/{emp}/salary-structures', auth_headers)[1]['structures'][0]
    assert listed()['locked'] is False
    code, body = _call('post', '/api/payroll', auth_headers,
                       {'employee_id': emp, 'month': 3, 'year': 2041, 'basic_salary': 7100.0, 'status': 'approved'})
    assert code == 201, body
    code, body = _call('put', f'/api/salary-structures/{structure}', auth_headers, {'basic': 8000})
    assert code == 409 and '3/2041' in body['error'], body
    assert _call('delete', f'/api/salary-structures/{structure}', auth_headers)[0] == 409
    assert listed()['locked'] is True, 'said before it is tried (HR-UX ط2)'


def test_a_new_structure_is_offered_from_the_first_month_still_open_to_it(auth_headers):
    """HR-UX ط1 (2 Nov 2026): offered from this month's first, a structure
    left him out of the month before's run, not yet drafted."""
    url = lambda emp: f'/api/employees/{emp}/salary-structures'
    emp = _employee(auth_headers, hire_date='2041-02-10')[1]['id']
    assert _call('get', url(emp), auth_headers)[1]['suggested_from'] == '2041-02-10', 'none approved: his hire'
    _call('post', url(emp), auth_headers, {'effective_from': '2041-02-10', 'basic': 7000})
    code, body = _call('post', '/api/payroll', auth_headers,
                       {'employee_id': emp, 'month': 12, 'year': 2041, 'basic_salary': 7000.0, 'status': 'approved'})
    assert code == 201, body
    assert _call('get', url(emp), auth_headers)[1]['suggested_from'] == '2042-01-01', 'the month after his last'


# ── contribution schemes ───────────────────────────────────────────────────────

def test_contributions_are_a_scheme_s_dated_rates_on_their_capped_base(auth_headers):
    code, scheme = _call('post', '/api/contribution-schemes', auth_headers, {'name': f'خطة {uuid.uuid4().hex[:6]}'})
    assert code == 201, scheme
    components = f"/api/contribution-schemes/{scheme['id']}/components"
    for row in ({'code': 'annuities', 'name': 'المعاشات', 'employee_rate': 9, 'employer_rate': 9},
                {'code': 'hazards', 'name': 'الأخطار المهنية', 'employee_rate': 0, 'employer_rate': 2}):
        code, body = _call('post', components, auth_headers,
                           {**row, 'base': 'basic_housing', 'base_cap': 45000, 'effective_from': '2026-01-01'})
        assert code == 201, body
    _call('post', components, auth_headers, {'code': 'annuities', 'name': 'المعاشات', 'base': 'basic_housing',
                                             'employee_rate': 10, 'employer_rate': 10, 'base_cap': 45000,
                                             'effective_from': '2027-07-01'})
    assert _call('post', components, auth_headers, {'code': 'x', 'name': 'x', 'base': 'net',
                                                    'effective_from': '2026-01-01'})[0] == 400

    emp = _employee(auth_headers, contribution_scheme_id=scheme['id'])[1]['id']
    _call('post', f'/api/employees/{emp}/salary-structures', auth_headers,
          {'effective_from': '2026-01-01', 'basic': 40000, 'housing': 10000, 'transport': 4000})
    rows = {r['code']: r for r in _call('get', f'/api/employees/{emp}/contributions?day=2026-11-01',
                                        auth_headers)[1]['contributions']}
    assert rows['annuities']['base_amount'] == 45000.0, 'basic + housing, capped'
    assert (rows['annuities']['employee_share'], rows['hazards']['employer_share']) == (4050.0, 900.0)
    later = {r['code']: r for r in _call('get', f'/api/employees/{emp}/contributions?day=2027-08-01',
                                         auth_headers)[1]['contributions']}
    assert later['annuities']['employee_share'] == 4500.0, 'a new rate from its day'


# ── how an employee is paid ────────────────────────────────────────────────────

def test_an_employee_is_paid_by_bank_with_a_checked_iban_or_by_cash(auth_headers):
    assert _employee(auth_headers, payment_method='cheque')[0] == 400
    assert _employee(auth_headers, payment_method='bank', iban='SA0380000000608010167518')[0] == 400, \
        'its check digits do not match'
    code, body = _employee(auth_headers, payment_method='bank', iban='sa03 8000 0000 6080 1016 7519',
                           bank_name='الراجحي')
    assert code in (200, 201), body
    assert (body['payment_method'], body['iban']) == ('bank', 'SA0380000000608010167519')
    code, body = _call('put', f"/api/employees/{body['id']}", auth_headers, {'payment_method': 'cash'})
    assert code == 200 and body['payment_method'] == 'cash'


# ── the guard: no rate written in the payroll's code ───────────────────────────

PAYROLL_CODE = sorted((Path(__file__).resolve().parents[1] / 'services').glob('payroll_*.py'))
POLICY_NUMBERS = {30, 45000}          # the day divisor and the GOSI cap -- data, never code


def _numbers_written(path: Path):
    for node in ast.walk(ast.parse(path.read_text(encoding='utf-8'))):
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            if (isinstance(node.value, float) and node.value != 0.0) or node.value in POLICY_NUMBERS:
                yield node.lineno, node.value


def test_no_rate_is_written_in_the_payroll_s_code():
    """A fraction in the payroll's code is a rate, and a rate is the owner's
    to edit («النسب ... قابلة للتعديل»): it lives in the policy or a scheme."""
    assert PAYROLL_CODE, 'the payroll services moved'
    written = {path.name: list(_numbers_written(path)) for path in PAYROLL_CODE}
    assert all(not found for found in written.values()), written


def test_a_figure_is_unset_again_by_null_not_zeroed(auth_headers):
    """The owner, 1 Nov 2026: a figure set is unset again, its part not reckoned."""
    _policy(auth_headers)
    code, body = _call('put', '/api/payroll/policy', auth_headers, {'housing_ratio': None, 'transport_ratio': 0})
    assert code == 200, body
    assert 'housing_ratio' not in body['policy'] and body['policy']['transport_ratio'] == 0.0
    code, body = _call('get', '/api/payroll/structure-suggestion?gross=10000', auth_headers)
    assert code == 400 and body.get('code') == 'payroll_policy_not_set', 'unset, not 0'


def test_an_empty_rate_is_refused_a_zero_is_typed(auth_headers):
    code, scheme = _call('post', '/api/contribution-schemes', auth_headers, {'name': f'خطة {uuid.uuid4().hex[:6]}'})
    url = f"/api/contribution-schemes/{scheme['id']}/components"
    row = {'code': 'hazards', 'name': 'الأخطار المهنية', 'base': 'basic_housing', 'effective_from': '2026-01-01'}
    assert _call('post', url, auth_headers, {**row, 'employee_rate': None, 'employer_rate': 2})[0] == 400
    code, body = _call('post', url, auth_headers, {**row, 'employee_rate': '0', 'employer_rate': '2'})
    assert code == 201 and (body['employee_rate'], body['employer_rate']) == (0.0, 2.0), body
