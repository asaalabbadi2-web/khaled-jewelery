"""An employee stopped is a user stopped; every change to his file is recorded (EMP-1, ش1).

The owner, 1 Nov 2026, on the employees' study:
  - «أوقف دخول الموظفَين الموقوفَين فورًا؟ نعم» -- on the 1 Nov copy the users
    of the two stopped employees (abr, sulimani) were active: login read the
    user's flag alone, and stopping an employee set his own;
  - «إذا كانت عهدة الموظف قائمة: يُسمح مع تنبيه» -- his gold or cash custody
    is said, not a refusal;
  - and no row of the audit log named an employee: his salary, his status,
    his deletion left no trace.
The laws, asked by every route that stops, edits, makes or deletes one:
  1. stopping an employee stops each user of his and revokes its sessions;
     starting him again does not start them (a user is started on its own);
  2. login refuses a user whose employee is stopped (services' second wall);
  3. stopping him with custody open is allowed, its balances said;
  4. each change of his file is recorded: who, when, each field before and
     after (his photo apart);
  5. his file's edit does not write what another document owns (HR-UX ط1,
     the owner, 2 Nov 2026: «اعتمد»): his salary is his salary structure's
     (services/payroll_policy follows it into the file), his leaving date is
     his end-of-service settlement's (services/employee_termination).
tests/test_employee_access_and_audit.py.
"""
from __future__ import annotations

import json
from datetime import date, datetime

from models import AppUser, AuditLog, Employee, RefreshToken, SafeBox, db

ENTITY = 'Employee'
UNRECORDED = ('photo', 'updated_at', 'created_at')


def snapshot(employee) -> dict:
    """His file as recorded: each column, his photo apart."""
    row = {}
    for column in Employee.__table__.columns:
        if column.name in UNRECORDED:
            continue
        value = getattr(employee, column.name)
        row[column.name] = value.isoformat() if isinstance(value, (date, datetime)) else value
    return row


def refuse_owned_elsewhere(data: dict, employee=None) -> None:
    """Law 5: a salary or a leaving date sent to his file, other than what it
    holds, is refused -- said where it is written instead."""
    from services.payroll_laws import PayrollRefused
    salary = data.get('salary')
    held = round(float(employee.salary or 0.0), 2) if employee is not None else 0.0
    try:
        sent = round(float(salary), 2) if salary not in (None, '') else held
    except (TypeError, ValueError):
        sent = None
    if sent != held:
        raise PayrollRefused('الراتب يُكتب من هيكل الراتب في قسم «الراتب»، لا من بيانات الموظف',
                             'salary_is_the_structure')
    leaving = data.get('termination_date') or None
    held_leaving = employee.termination_date.isoformat() if employee is not None and employee.termination_date else None
    if 'termination_date' in data and leaving != held_leaving:
        raise PayrollRefused('تاريخ ترك العمل يُسجَّل من «إنهاء الخدمة» مع تسويته، لا من بيانات الموظف',
                             'termination_is_the_settlement')


def record(employee, *, action: str, before: dict | None, by: str, now, extra: dict | None = None):
    """Law 4: the change, field by field. Nothing changed, nothing recorded. Caller commits."""
    after = snapshot(employee) if action != 'delete_employee' else None
    if before is not None and after is not None:
        changes = {k: {'before': before.get(k), 'after': v} for k, v in after.items() if before.get(k) != v}
    else:
        changes = {'before': before, 'after': after}
    if not changes and not extra:
        return None
    entry = AuditLog(user_name=by, action=action, entity_type=ENTITY, entity_id=employee.id,
                     entity_number=employee.employee_code, success=True, timestamp=now,
                     details=json.dumps({'changes': changes, **(extra or {})}, ensure_ascii=False, default=str))
    db.session.add(entry)
    return entry


def close_access(employee, *, now) -> list[str]:
    """Law 1: each user of his stopped, its sessions revoked. Caller commits."""
    closed = []
    for user in AppUser.query.filter_by(employee_id=employee.id):
        if user.is_active:
            user.is_active = False
            closed.append(user.username)
        for token in RefreshToken.query.filter_by(user_id=user.id, user_type='app_user', is_revoked=False):
            token.is_revoked, token.revoked_at, token.revoked_reason = True, now, 'employee_inactive'
    return closed


def custody_of(employee) -> dict:
    """Law 3: what his gold and cash custody hold, from the books -- the open part only."""
    from services.live_balances import live_balances_by_account_ids
    open_ = {}
    for kind, safe_id in (('gold', employee.gold_safe_box_id), ('cash', employee.cash_safe_box_id)):
        safe = db.session.get(SafeBox, safe_id) if safe_id else None
        if safe is None or not safe.account_id:
            continue
        balance = live_balances_by_account_ids([safe.account_id]).get(safe.account_id, {})
        held = {key: round(value, 3) for key, value in balance.items()
                if round(value, 3) and (key != 'cash' or kind == 'cash')}
        if held:
            open_[kind] = {'safe': safe.name, 'balances': held}
    return open_


def stop(employee, *, by: str, now, before: dict | None = None) -> dict:
    """Stopped: his users closed, his open custody said, the change recorded. Caller commits."""
    before = before if before is not None else snapshot(employee)
    employee.is_active = False
    closed = close_access(employee, now=now)
    custody = custody_of(employee)
    record(employee, action='stop_employee', before=before, by=by, now=now,
           extra={'users_closed': closed, 'custody_open': custody})
    return {'users_closed': closed, 'custody_open': custody, 'warning': custody_warning(custody)}


def custody_warning(custody: dict) -> str | None:
    if not custody:
        return None
    parts = []
    for kind, row in custody.items():
        held = '، '.join(f'{v:,.3f} جم عيار {k[:-1]}' if k != 'cash' else f'{v:,.2f} ريال'
                         for k, v in row['balances'].items())
        parts.append(f'{row["safe"]}: {held}')
    return 'أُوقف الموظف وعهدته قائمة -- ' + '؛ '.join(parts) + '. تُسلَّم العهدة أو تُسوّى.'


def refuse_login_message(app_user) -> str | None:
    """Law 2: a user whose employee is stopped does not sign in."""
    if app_user.employee_id is None:
        return None
    employee = db.session.get(Employee, app_user.employee_id)
    if employee is not None and not employee.is_active:
        return 'الموظف المرتبط بهذا الحساب موقوف'
    return None
