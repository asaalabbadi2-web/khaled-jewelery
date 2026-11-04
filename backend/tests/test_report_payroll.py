"""The payroll report: the period's salaries by month, employee or line, against the salary expense (REPORTS ت6-2ب, ADR-083).

From the payroll's lines, approved or paid: what each earned, its additions,
its bonuses (paid from the bonus payables, not the expense), its absence
(not earned) and its other deductions, its net -- and its salary expense,
the run's own reckoning (services/payroll_run.line_parts) or, for a salary
accrued alone before the runs, its net (routes/employees' accrual). On the 2
Nov copy October's run is 67,385 earned and bonused, its expense 41,667: the
bonuses (22,385) and the absence (3,333) are not the expense. Checked against
the books: the salary expense's net debit in the period's months, dated its
month's last day since ت6-2أ.

Run:
    python -m pytest tests/test_report_payroll.py -v
"""
import datetime as dt

import pytest

from tests.test_payroll_is_kept_whole import _employee, _payroll
from tests.test_payroll_run import MONTH, YEAR, _call, _run, staff  # noqa: F401 (fixture)

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _report(by='month', start=dt.date(YEAR, 3, 1), end=dt.date(YEAR, MONTH, 30)):
    from services.reports.payroll import payroll_report
    return payroll_report(start=start, end=end, by=by, now=D(YEAR, 6, 1))


def _rows(report):
    return {r['group']: r for r in report.rows if r.get('style') is None}


@pytest.fixture
def paid(auth_headers, staff):
    run = _run(auth_headers)[1]
    code, body = _call('post', f"/api/payroll/runs/{run['id']}/approve", auth_headers)
    assert code == 200, body
    legacy = _payroll(auth_headers, _employee(auth_headers), month=3, year=YEAR, basic_salary=5000.0,
                      status='approved')[1]
    return {'run': body, 'legacy': legacy}


def test_by_month_each_month_s_salaries_and_its_expense(paid):
    from services.payroll_run import line_parts
    from models import Payroll
    report = _report()
    april = _rows(report)[f'{YEAR}-{MONTH:02d}']
    lines = Payroll.query.filter_by(payroll_run_id=paid['run']['id']).all()
    assert april['expense'] == pytest.approx(sum(line_parts(l)['salary_expense'] for l in lines))
    assert april['net'] == pytest.approx(paid['run']['totals']['net_salary'])
    march = _rows(report)[f'{YEAR}-03']
    assert march['expense'] == pytest.approx(5000.0) and march['net'] == pytest.approx(5000.0)
    assert {c.key: c.ok for c in report.checks} == {'books_agree': True}


def test_by_employee_each_opens_his_page(paid, staff):
    rows = {r['drill']['id']: r for r in _report('employee').rows if r.get('drill')}
    assert staff['full'] in rows and rows[staff['full']]['drill'] == {'kind': 'employee', 'id': staff['full']}


def test_by_line_each_salary_with_its_month(paid, staff):
    report = _report('line')
    assert len([r for r in report.rows if r.get('style') is None]) == len(paid['run']['entries']) + 1
    assert any(f'{YEAR}-{MONTH:02d}' in r['group'] for r in report.rows)
