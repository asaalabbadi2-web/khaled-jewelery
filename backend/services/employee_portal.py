"""The employee's portal: his own, and nobody else's (EMP-PORTAL-1, ش6).

The owner, 1 Nov 2026 («انتقل لبوابة الموظف»): a part of the app where each
employee, signed in as himself, sees what is his -- his payslips, his leave
and its balance, his advance, his bonuses and goals -- and asks for leave.
The security laws (§5, Law 5: no object by its id alone):

  1. the employee is the session's -- never an id from the request; a user
     with no employee, or a stopped one, has no portal;
  2. a payslip is his only if its line is his, approved or paid -- another's
     is not found, not refused (nothing said of it);
  3. a leave he asks for is a request, whatever the request says -- the
     manager approves it (services/employee_leave); he cancels his own
     request alone, not an approved leave;
  4. nothing here writes but his request and its cancelling.
Each part is its owner's reader. tests/test_employee_portal.py.
"""
from __future__ import annotations

from datetime import date

from models import Employee, EmployeeBonus, EmployeeLeave, LeaveType, Payroll, db
from services.payroll_laws import PayrollRefused

SHOWN = ('approved', 'paid')
RECENT = 12


def mine(user):
    """Law 1: the session's employee, active -- or None."""
    employee_id = getattr(user, 'employee_id', None)
    employee = db.session.get(Employee, employee_id) if employee_id else None
    return employee if employee is not None and employee.is_active else None


def portal(employee, *, today: date) -> dict:
    from services.employee_leave import balances
    from services.goal_achievements import goal_progress
    from services.payroll_advances import account_balance, to_dict as plan_dict
    lines = (Payroll.query.filter(Payroll.employee_id == employee.id, Payroll.status.in_(SHOWN))
             .order_by(Payroll.year.desc(), Payroll.month.desc()).limit(RECENT).all())
    bonuses = (EmployeeBonus.query.filter(EmployeeBonus.employee_id == employee.id,
                                          EmployeeBonus.status.in_(('approved', 'paid')))
               .order_by(EmployeeBonus.id.desc()).limit(6).all())
    try:
        goals = goal_progress(employee, today)
    except Exception:                     # noqa: BLE001 -- a goal not set says nothing, the portal stands
        goals = []
    return {
        'employee': {'name': employee.name, 'employee_code': employee.employee_code,
                     'job_title': employee.job_title,
                     'hire_date': employee.hire_date.isoformat() if employee.hire_date else None},
        'payslips': [{'id': p.id, 'month': p.month, 'year': p.year, 'net_salary': p.net_salary,
                      'status': p.status} for p in lines],
        'leave': {'balances': balances(employee, today),
                  'mine': [l.to_dict() for l in employee.leaves.order_by(EmployeeLeave.start_date.desc()).limit(10)],
                  'kinds': [{'id': k.id, 'name': k.name, 'paid': k.paid}
                            for k in LeaveType.query.filter_by(is_active=True).order_by(LeaveType.id)]},
        'advance': {'balance': account_balance(employee),
                    'plans': [plan_dict(p) for p in employee.advance_plans if p.status == 'active']},
        'bonuses': [{'amount': b.amount, 'status': b.status,
                     'period_end': b.period_end.isoformat() if b.period_end else None} for b in bonuses],
        'goals': goals,
    }


def payslip(employee, payroll_id: int):
    """Law 2: his line, approved or paid -- else None (not found)."""
    from services.payroll_run import payslip as slip
    entry = db.session.get(Payroll, payroll_id)
    if entry is None or entry.employee_id != employee.id or entry.status not in SHOWN:
        return None
    return slip(entry)


def request_leave(employee, data: dict, *, by: str, now):
    """Law 3: a request, whatever was asked. Caller commits."""
    from services.employee_leave import record
    return record(employee.id, {**(data or {}), 'status': 'requested'}, by=by, now=now)


def cancel_request(employee, leave_id: int, *, by: str, now):
    """Law 3: his own request, not yet decided. Caller commits."""
    from services.employee_leave import cancel
    leave = db.session.get(EmployeeLeave, leave_id)
    if leave is None or leave.employee_id != employee.id:
        return None
    if leave.status != 'requested':
        raise PayrollRefused('يُلغي الموظف طلبه الذي لم يُبتّ فيه وحده؛ الإجازة المعتمدة يلغيها المدير')
    cancel(leave, by=by, now=now)
    return leave
