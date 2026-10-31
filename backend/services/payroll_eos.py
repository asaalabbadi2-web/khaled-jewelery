"""The end-of-service provision, booked by each month's run (PAYROLL-5, M4).

The owner, 1 Nov 2026 («اودع وانتقل»; «طبّق النظام الأفضل والأشمل»). On the 31
Oct copy no provision had ever been booked, and no employee had a hire date.
The Labour Law (art. 84): half a month's wage for each of the first years, a
month's wage for each year after, a part of a year by its days -- on the
actual wage (art. 2: the basic and the allowances paid with it). The provision
is the whole entitlement, as if the contract ended by the employer at the
month's end; a resignation's smaller share (art. 85) is settled when it comes.

Each run's line says the provision of its month: the entitlement at the
month's end less what his end-of-service account holds already (counted
lines) -- a raise is caught up, a cut given back. Booked by the run's accrual:
    Dr end-of-service expense / Cr his end-of-service payable.
The rates, the years and the wage's base are the policy's, and none is seeded
(the owner, 1 Nov 2026: «ابنِ هيكله ولا تضع أي أرقام»): until he enters them,
or with no hire date, nothing is booked and the line says why -- the run goes
on. tests/test_payroll_eos.py.
"""
from __future__ import annotations

from datetime import date

from services.payroll_laws import PayrollRefused
from services.payroll_policy import PayrollPolicyNotSet, require

DAYS_IN_A_YEAR = 365
EOS_PAYABLE = 'eos_payable'
EOS_EXPENSE = 'eos_expense'


def wage_of(structure) -> float:
    base = require('eos_wage_base')
    if base == 'basic':
        return structure.basic
    if base == 'basic_housing':
        return round(structure.basic + structure.housing, 2)
    if base == 'gross':
        return structure.gross
    raise PayrollRefused(f'وعاء مكافأة نهاية الخدمة غير معروف: {base}')


def entitlement(hire_date: date, day: date, wage: float) -> tuple[int, float]:
    """(days served, the art. 84 entitlement on the day)."""
    days = (day - hire_date).days + 1
    if days <= 0:
        return 0, 0.0
    years = days / DAYS_IN_A_YEAR
    first_years = float(require('eos_first_years'))
    first = min(years, first_years) * float(require('eos_first_years_months')) * wage
    after = max(years - first_years, 0) * float(require('eos_after_years_months')) * wage
    return days, round(first + after, 2)


def booked(employee) -> float:
    """What his end-of-service account holds (credit less debit, counted lines)."""
    from services.employee_accounts import employee_account
    from services.live_balances import live_balances_by_account_ids
    account = employee_account(employee, EOS_PAYABLE)
    if account is None:
        return 0.0
    return round(-float(live_balances_by_account_ids([account.id]).get(account.id, {}).get('cash', 0.0)), 2) + 0.0


def provision(employee, structure, last_day: date) -> dict:
    """The month's provision for the line's breakdown."""
    if employee.hire_date is None:
        return {'reason': 'no_hire_date', 'provision': 0.0}
    end = min(employee.termination_date, last_day) if employee.termination_date else last_day
    try:
        wage = wage_of(structure)
        days, owed = entitlement(employee.hire_date, end, wage)
    except PayrollPolicyNotSet:
        return {'reason': 'policy_not_set', 'provision': 0.0}
    held = booked(employee)
    return {'days': days, 'wage': wage, 'entitlement': owed, 'booked': held,
            'provision': round(owed - held, 2)}
