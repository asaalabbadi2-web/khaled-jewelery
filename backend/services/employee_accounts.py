"""An employee's accounts: found by an explicit link, made under a mapped parent (CHART-002, ADR-046).

The code found an employee's payables by the employee's name under a parent it
knew by number (2400, 2410, 2420, 2310), and built the parents themselves when
missing -- 240, 2400.., 2310, 1700, 170 -- by their 2026 numbers; the gold
custody group was renumbered, re-parented and pruned on every employee
created. The owner, 14 Oct 2026: the chart is data, the links are explicit.

- A parent is a role (accounting_mapping, the default operation). Missing, the
  employee's account is refused -- no account is created in its place.
- An employee's account for a role is a row of employee_account. Made once,
  under the role's parent, named by the naming rules, and linked.
"""
from __future__ import annotations

from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
from models import Account, EmployeeAccount, db

# Where each kind of employee account lives (a parent role) and its name's category.
PAYABLE_ROLES = {
    'salary_payable': ('employee_salary_payable_parent', 'رواتب'),
    'commission_payable': ('employee_commission_payable_parent', 'عمولات'),
    'eos_payable': ('employee_eos_payable_parent', 'نهاية الخدمة'),
    'bonus_payable': ('employee_bonus_payable_parent', 'مكافآت'),
}
PERSONAL_PARENT = 'employee_personal_parent'
GOLD_CUSTODY_PARENT = 'employee_gold_custody_parent'
CASH_CUSTODY_PARENT = 'employee_cash_custody_parent'
SALARY_EXPENSE = 'salary_expense'
BONUS_EXPENSE = 'bonus_expense'

# The structure roles: each must be mapped (accounting.mappings.REQUIRED_ROLES).
STRUCTURE_ROLES = (PERSONAL_PARENT, *(parent for parent, _ in PAYABLE_ROLES.values()),
                   GOLD_CUSTODY_PARENT, CASH_CUSTODY_PARENT, SALARY_EXPENSE, BONUS_EXPENSE)


def parent_account(role: str) -> Account:
    """The account a structure role is mapped to -- or AccountNotMapped."""
    return db.session.get(Account, require_account(DEFAULT_MAPPING_OPERATION_TYPE, role))


def employee_account(employee, role: str):
    """The employee's account for *role*, by its link -- or None."""
    if employee is None or getattr(employee, 'id', None) is None:
        return None
    row = EmployeeAccount.query.filter_by(employee_id=employee.id, role=role).first()
    return row.account if row else None


def link(employee, role: str, account: Account, *, by: str = 'system') -> Account:
    row = EmployeeAccount.query.filter_by(employee_id=employee.id, role=role).first()
    if row is None:
        db.session.add(EmployeeAccount(employee_id=employee.id, role=role, account_id=account.id,
                                       created_by=by))      # created_at: the model's default
    else:
        row.account_id = account.id
    db.session.flush()
    return account


def ensure_payable_account(employee, role: str, *, by: str = 'system') -> Account:
    """The employee's account for a payable role: linked, or made under its parent and linked."""
    from account_number_generator import get_next_account_number
    from employee_account_naming import employee_payable_account_name

    found = employee_account(employee, role)
    if found is not None:
        return found
    parent_role, category = PAYABLE_ROLES[role]
    parent = parent_account(parent_role)
    account = Account(account_number=str(get_next_account_number(str(parent.account_number))),
                      name=employee_payable_account_name(employee.name, category_ar=category),
                      type='Liability', transaction_type='cash', tracks_weight=False, parent_id=parent.id)
    db.session.add(account)
    db.session.flush()
    return link(employee, role, account, by=by)


def ensure_payable_accounts(employee, *, by: str = 'system') -> list:
    """The employee's four payable accounts (salaries, commissions, end of service, bonuses)."""
    return [ensure_payable_account(employee, role, by=by) for role in PAYABLE_ROLES]
