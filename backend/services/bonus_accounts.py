"""An employee's bonus payable account, and what the books say each is owed (BONUS-BOOKS-1).

The books are right (the owner, 14 Oct 2026): a payment voucher, its reversal
or a manual entry on an employee's bonus account changes what the employee is
owed without passing through the bonus's status. The bonus screen and the
payables report read the owed amount from the books; the bonuses stay the
documents they are -- no voucher is attributed to a bonus by guess (no FIFO).

One rule finds the account -- approval, payment, reversal and this reader
used three copies of it.
"""
from __future__ import annotations

from sqlalchemy import func

from models import Account, Employee, EmployeeBonus, db

PAYABLE_PREFIX = '2310'


def employee_bonus_account(employee: Employee | None) -> Account | None:
    """The employee's 2310xxx account -- the one their bonuses post to."""
    if employee is None:
        return None
    return (Account.query
            .filter(Account.account_number.like(f'{PAYABLE_PREFIX}%'),
                    Account.name.like(f'%{employee.name}%'))
            .first())


def owed_by_employee() -> list[dict]:
    """Per employee: owed in the books (credit less debit on their bonus account,
    counted lines) beside their approved, unpaid bonuses; the difference is what
    was paid, reversed or entered in the books outside the bonus screen."""
    from services.live_balances import live_balances_by_account_ids

    approved = dict(db.session.query(EmployeeBonus.employee_id, func.sum(EmployeeBonus.amount))
                    .filter(EmployeeBonus.status == 'approved')
                    .group_by(EmployeeBonus.employee_id).all())
    accounts = {}
    for employee in Employee.query.order_by(Employee.id).all():
        account = employee_bonus_account(employee)
        if account is not None:
            accounts[employee.id] = (employee, account)
    live = live_balances_by_account_ids([a.id for _, a in accounts.values()])

    rows = []
    for employee_id, (employee, account) in accounts.items():
        owed = round(-float(live.get(account.id, {}).get('cash', 0.0)), 2) + 0.0   # never -0.0
        unpaid = round(float(approved.get(employee_id) or 0.0), 2)
        if abs(owed) < 0.005 and abs(unpaid) < 0.005:
            continue
        rows.append({
            'employee_id': employee_id,
            'employee_name': employee.name,
            'employee_code': employee.employee_code,
            'account_number': account.account_number,
            'owed_in_books': owed,
            'approved_unpaid': unpaid,
            'difference': round(unpaid - owed, 2),
        })
    return rows
