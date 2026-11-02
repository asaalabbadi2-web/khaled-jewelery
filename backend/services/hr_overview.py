"""The HR hub's overview: its indicators, its employees' rows, what needs doing (HR-UX ر1).

The owner, 1 Nov 2026 («اعتمد» the one-screen design,
docs/plans/hr-ux-redesign-2026-11.md). One reading for the hub's «الموظفون»
and «المتابعة» tabs; nothing reckoned here -- each figure is its owner's
reader: the structure in force (payroll_policy), the payroll lines, the
books (live_balances, bonus_accounts), the custody (employee_access), the
missing data (employee_file), the documents (employee_documents), the leave
(employee_leave), the terminations (employee_termination).
tests/test_hr_overview.py.
"""
from __future__ import annotations

from datetime import date

from models import Employee, EmployeeLeave, EmployeeTermination, Payroll, PayrollRun, db

UNSET_WATCHED = ('eos_wage_base', 'eos_first_years', 'eos_first_years_months', 'eos_after_years_months',
                 'eos_resign_min_years', 'contract_alert_days')


def _last_line(employee):
    return (Payroll.query.filter(Payroll.employee_id == employee.id, Payroll.status != 'cancelled')
            .order_by(Payroll.year.desc(), Payroll.month.desc()).first())


def _row(employee, today: date) -> dict:
    from services.bonus_accounts import owed_in_books
    from services.employee_access import custody_of
    from services.employee_accounts import employee_account
    from services.employee_file import _missing
    from services.employee_termination import _credit
    from services.payroll_advances import gold_balance
    from services.payroll_policy import structure_on
    structure = structure_on(employee.id, today)
    line = _last_line(employee)
    salary_payable = employee_account(employee, 'salary_payable')
    return {
        'id': employee.id, 'name': employee.name, 'employee_code': employee.employee_code,
        'job_title': employee.job_title, 'is_active': bool(employee.is_active),
        'gross': structure.gross if structure is not None else None,
        'last_payroll': ({'month': line.month, 'year': line.year, 'status': line.status,
                          'net_salary': line.net_salary} if line is not None else None),
        'advance': round(-_credit(employee.account_id), 2) + 0.0,
        'advance_gold': gold_balance(employee),            # his gold advance, by karat
        'custody': custody_of(employee),
        'missing': _missing(employee),
        'salary_owed': _credit(salary_payable.id) if salary_payable is not None else 0.0,
        'bonuses_owed': owed_in_books(employee),
    }


def _month_cost() -> dict | None:
    """The latest month paid or approved: its lines' net, its month."""
    latest = (Payroll.query.filter(Payroll.status.in_(('approved', 'paid')))
              .order_by(Payroll.year.desc(), Payroll.month.desc()).first())
    if latest is None:
        return None
    lines = Payroll.query.filter(Payroll.year == latest.year, Payroll.month == latest.month,
                                 Payroll.status.in_(('approved', 'paid'))).all()
    return {'month': latest.month, 'year': latest.year, 'net': round(sum(l.net_salary or 0.0 for l in lines), 2),
            'paid': all(l.status == 'paid' for l in lines)}


def _followup(rows: list[dict], today: date) -> list[dict]:
    from services.employee_documents import expiring
    from services.payroll_policy import policy
    items = []
    previous = (today.year, today.month - 1) if today.month > 1 else (today.year - 1, 12)
    month_lines = Payroll.query.filter(Payroll.year == previous[0], Payroll.month == previous[1],
                                       Payroll.status != 'cancelled').count()
    run = PayrollRun.query.filter(PayrollRun.year == previous[0], PayrollRun.month == previous[1],
                                  PayrollRun.status != 'cancelled').first()
    if run is None and not month_lines:
        items.append({'kind': 'run_missing', 'tone': 'blocked', 'month': previous[1], 'year': previous[0],
                      'last': _month_cost()})
    elif run is not None and run.status != 'paid':
        items.append({'kind': 'run_open', 'tone': 'blocked', 'month': run.month, 'year': run.year,
                      'status': run.status, 'run_id': run.id})
    incomplete = [r for r in rows if r['is_active'] and r['missing']]
    if incomplete:
        items.append({'kind': 'missing_data', 'tone': 'warning',
                      'employees': [{'id': r['id'], 'name': r['name'], 'missing': r['missing']} for r in incomplete]})
    held = policy()
    unset = [key for key in UNSET_WATCHED if key not in held]
    if unset:
        items.append({'kind': 'policy_unset', 'tone': 'warning', 'keys': unset})
    for document in expiring(today):
        items.append({'kind': 'expiring', 'tone': 'blocked' if document['days_left'] < 0 else 'warning', **document})
    requests = EmployeeLeave.query.filter_by(status='requested').count()
    on_leave = (EmployeeLeave.query.filter(EmployeeLeave.status == 'approved', EmployeeLeave.start_date <= today,
                                           EmployeeLeave.end_date >= today).count())
    if requests or on_leave:
        items.append({'kind': 'leave', 'tone': 'info', 'requests': requests, 'on_leave': on_leave})
    unpaid = EmployeeTermination.query.filter_by(status='approved').all()
    for termination in unpaid:
        items.append({'kind': 'termination_unpaid', 'tone': 'warning', 'employee_id': termination.employee_id,
                      'employee': termination.employee.name, 'termination_id': termination.id,
                      'last_day': termination.last_day.isoformat()})
    custody = [{'id': r['id'], 'name': r['name'], 'custody': r['custody']} for r in rows if r['custody']]
    if custody:
        items.append({'kind': 'custody', 'tone': 'info', 'employees': custody})
    return items


def overview(*, today: date) -> dict:
    from services.employee_documents import expiring
    rows = [_row(employee, today) for employee in Employee.query.order_by(Employee.id)]
    active = [r for r in rows if r['is_active']]
    return {
        'kpis': {'active': len(active), 'stopped': len(rows) - len(active), 'month_cost': _month_cost(),
                 'expiring': len(expiring(today)), 'incomplete': sum(1 for r in active if r['missing'])},
        'employees': rows,
        'followup': _followup(rows, today),
    }
