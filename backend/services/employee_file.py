"""An employee's file, in one place (EMP-2, ش2) -- read from the services that own each part.

The owner, 1 Nov 2026 («اودع ثم انتقل»), on the employees' study: what the
system knows of an employee lay on six screens -- his data, his structure, his
payroll, his advances, his bonuses, his custody, his accounts -- and some of it
on none (his custody, what the books owe him). Nothing is reckoned here; each
part is its owner's reader:

  - his data, and what of it is missing (the 1 Nov copy: no national id and
    no hire date for anyone);
  - his users;
  - his salary: the structure in force, his scheme and registered wage, how
    he is paid (services/payroll_policy);
  - his last payroll lines;
  - his advances: the account's balance, the plans (services/payroll_advances);
  - his bonuses: approved unpaid beside what the books owe (services/bonus_accounts);
  - his custody (services/employee_access);
  - each of his accounts' balances, from the books (services/live_balances);
  - his goals so far (services/goal_achievements);
  - his contract in force and his documents (services/employee_documents, EMP-3);
  - his leave balances and last leaves (services/employee_leave, EMP-4);
  - his end of service and its settlement (services/employee_termination, EMP-5).
tests/test_employee_file.py.
"""
from __future__ import annotations

from datetime import date

from models import AppUser, EmployeeAccount, EmployeeBonus, EmployeeLeave, EmployeeTermination, Payroll, db

RECENT_LINES = 6
MISSING = (('national_id', 'الهوية الوطنية / الإقامة'), ('hire_date', 'تاريخ التعيين'),
           ('job_title', 'المسمى الوظيفي'), ('phone', 'الجوال'))


def completeness(employee) -> dict:
    """How much of his file is there (HR-UX ر2's ring): the checks _missing
    asks of him, and how many are met."""
    asked = len(MISSING) + 2                   # his structure and his payment method
    if employee.payment_method == 'bank':
        asked += 1                             # his IBAN
    if not employee.is_active:
        asked += 1                             # his termination date
    missing = len(_missing(employee))
    return {'done': asked - missing, 'of': asked}


def _missing(employee) -> list[str]:
    from services.payroll_policy import structure_on
    missing = [label for field, label in MISSING if not getattr(employee, field)]
    if structure_on(employee.id, date.max) is None:
        missing.append('هيكل الراتب')
    if not employee.payment_method:
        missing.append('طريقة الصرف')
    elif employee.payment_method == 'bank' and not employee.iban:
        missing.append('الآيبان')
    if not employee.is_active and not employee.termination_date:
        missing.append('تاريخ الإنهاء')
    return missing


def _accounts(employee) -> list[dict]:
    from services.live_balances import live_balances_by_account_ids
    from models import Account
    rows = [('personal', employee.account_id)] + [(link.role, link.account_id)
                                                  for link in EmployeeAccount.query.filter_by(employee_id=employee.id)]
    live = live_balances_by_account_ids([account_id for _, account_id in rows if account_id])
    out = []
    for role, account_id in rows:
        account = db.session.get(Account, account_id) if account_id else None
        if account is None:
            continue
        balance = live.get(account_id, {})
        out.append({'role': role, 'account_id': account.id, 'account_number': account.account_number,
                    'name': account.name,
                    'cash': round(balance.get('cash', 0.0), 2)})
    return out


def file_of(employee, *, today: date) -> dict:
    from services.bonus_accounts import owed_in_books
    from services.employee_access import custody_of
    from services.goal_achievements import goal_progress
    from services.payroll_advances import account_balance, to_dict as plan_dict
    from services.employee_documents import contract_on, current_documents
    from services.employee_leave import balances as leave_balances
    from services.payroll_policy import structure_on
    structure = structure_on(employee.id, today)
    scheme = employee.contribution_scheme_id
    lines = (Payroll.query.filter(Payroll.employee_id == employee.id)
             .order_by(Payroll.year.desc(), Payroll.month.desc()).limit(RECENT_LINES).all())
    approved = EmployeeBonus.query.filter_by(employee_id=employee.id, status='approved').all()
    last_paid = (EmployeeBonus.query.filter_by(employee_id=employee.id, status='paid')
                 .order_by(EmployeeBonus.paid_at.desc().nullslast()).first())
    try:
        goals = goal_progress(employee, today)
    except Exception:                     # noqa: BLE001 -- a goal not set says nothing, the file stands
        goals = []
    from models import ContributionScheme
    return {
        'employee': employee.to_dict(),
        'missing': _missing(employee),
        'completeness': completeness(employee),
        'users': [{'username': u.username, 'role': u.role, 'is_active': u.is_active,
                   'last_login_at': u.last_login_at.isoformat() if u.last_login_at else None}
                  for u in AppUser.query.filter_by(employee_id=employee.id)],
        'salary': {
            'structure': structure.to_dict() if structure is not None else None,
            'scheme': (db.session.get(ContributionScheme, scheme).name if scheme else None),
            'contribution_wage': employee.contribution_wage,
            'payment_method': employee.payment_method, 'iban': employee.iban, 'bank_name': employee.bank_name,
        },
        'payroll': [{'id': p.id, 'month': p.month, 'year': p.year, 'net_salary': p.net_salary, 'status': p.status,
                     'payroll_run_id': p.payroll_run_id,
                     'voucher_number': p.voucher.voucher_number if p.voucher else None} for p in lines],
        'advances': {'account_balance': account_balance(employee),
                     'plans': [plan_dict(p) for p in employee.advance_plans if p.status == 'active']},
        'bonuses': {'approved_unpaid': round(sum((b.amount or 0.0 for b in approved), 0.0), 2),
                    'approved_count': len(approved), 'owed_in_books': owed_in_books(employee),
                    'last_paid_at': last_paid.paid_at.isoformat() if last_paid and last_paid.paid_at else None},
        'custody': custody_of(employee),
        'accounts': _accounts(employee),
        'goals': goals,
        'contract': (lambda c: c.to_dict() if c is not None else None)(contract_on(employee.id, today)),
        'documents': [d.to_dict() for d in current_documents(employee)],
        'leave': {'balances': leave_balances(employee, today),
                  'recent': [l.to_dict() for l in employee.leaves.order_by(EmployeeLeave.start_date.desc()).limit(5)]},
        'termination': (lambda t: t.to_dict() if t is not None else None)(
            employee.terminations.filter(EmployeeTermination.status != 'cancelled')
            .order_by(EmployeeTermination.id.desc()).first()),
    }
