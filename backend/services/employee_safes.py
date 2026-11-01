"""His own safe, made when it is asked for, by its name (HR-UX ط5).

The owner, 2 Nov 2026 («اعتمد»): the old screen's «إصلاح حسابات وخزائن
الموظف» made, in one press, his personal account, his four payables, and a
cash safe and a gold safe of his own -- moving an employee who works from
the main safe onto a new one nobody asked for (on the 1 Nov copy three of
the five active did). His accounts are made where they are first needed
(services/employee_accounts); what that button alone did is this, asked
for one kind at a time:

  1. a safe of his own -- cash or gold -- is made and linked only while he
     has none linked; one linked (his own or a shared one) is refused, said;
  2. the change of his file is recorded (services/employee_access, law 4).
tests/test_employee_own_safe.py.
"""
from __future__ import annotations

from services.payroll_laws import PayrollRefused

KINDS = {'cash': 'cash_safe_box_id', 'gold': 'gold_safe_box_id'}


def make_own_safe(employee, kind: str, *, by: str, now):
    """Law 1 and 2. Caller commits."""
    from services.employee_access import record, snapshot
    field = KINDS.get(kind)
    if field is None:
        raise PayrollRefused('نوع الخزنة نقد أو ذهب', 'safe_kind_unknown')
    if getattr(employee, field):
        raise PayrollRefused('له خزنة مربوطة لهذا النوع: يُختار «الخزنة الرئيسية» في «الخزائن» أولًا إن أُريدت غيرها',
                             'employee_has_a_safe')
    before = snapshot(employee)
    if kind == 'cash':
        from employee_cash_safe_helpers import create_employee_cash_safe as make
    else:
        from employee_gold_safe_helpers import create_employee_gold_safe as make
    _, safe = make(employee_name=employee.name, employee_code=employee.employee_code, created_by=by)
    setattr(employee, field, safe.id)
    record(employee, action='update_employee', before=before, by=by, now=now)
    return safe
