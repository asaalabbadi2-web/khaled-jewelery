"""The stopped employees' users stopped; the custody links to deleted safes cleared (EMP-1, ش0/ش1).

The owner, 1 Nov 2026 («أوقف دخول الموظفَين الموقوفَين فورًا؟ نعم»). On the 1
Nov copy: abr (ابو بشار) and sulimani (السليماني يوسف) -- both employees
stopped -- were active users, last in on 18 May and 21 Jun; and the cash
custody of صالح (safe 40) and يوسف (safe 54) named safes that are no more (no
foreign key held them). Stopping an employee closes his users now
(services/employee_access); this closes the ones stopped before, and clears
the dead links. dry_run (the default) writes nothing; an audit row names each.
"""
from __future__ import annotations

import json

from models import AppUser, AuditLog, Employee, SafeBox, db

ACTION = 'repair_employee_access_cleanup'


def cleanup(*, by: str, now, dry_run: bool = True) -> dict:
    from services.employee_access import close_access
    plan = {'users_closed': [], 'links_cleared': []}
    for employee in Employee.query.filter_by(is_active=False).order_by(Employee.id):
        users = [u.username for u in AppUser.query.filter_by(employee_id=employee.id, is_active=True)]
        if users:
            plan['users_closed'].append({'employee_id': employee.id, 'employee': employee.name, 'users': users})
            if not dry_run:
                close_access(employee, now=now)
    for employee in Employee.query.order_by(Employee.id):
        for column in ('gold_safe_box_id', 'cash_safe_box_id'):
            safe_id = getattr(employee, column)
            if safe_id and db.session.get(SafeBox, safe_id) is None:
                plan['links_cleared'].append({'employee_id': employee.id, 'employee': employee.name,
                                              'column': column, 'safe_id': safe_id})
                if not dry_run:
                    setattr(employee, column, None)
    if dry_run or not (plan['users_closed'] or plan['links_cleared']):
        return plan
    first = (plan['users_closed'] or plan['links_cleared'])[0]['employee_id']
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='Employee', entity_id=first, success=True,
                            timestamp=now, details=json.dumps(plan, ensure_ascii=False)))
    db.session.flush()
    return plan
