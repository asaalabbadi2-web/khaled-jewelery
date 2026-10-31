"""Payroll entries of a month that is not a month, removed (PAYROLL-1, م0; the owner, 1 Nov 2026).

The form took the year as free text: the 31 Oct copy held a pending entry for
December of «202» (#3, مسعد المهري, 10,000). The form and the server refuse such
a month now (services/payroll_laws.refuse_bad_period); this removes the ones
already saved -- pending, with no accrual and no voucher, nothing written for
them. dry_run (the default) removes nothing; an audit row names each removed.
"""
import json

from models import AuditLog, Payroll, db

ACTION = 'repair_payroll_stray_periods'


def remove_stray_periods(*, by: str, dry_run: bool = True) -> dict:
    from services.payroll_laws import PayrollRefused, refuse_bad_period, refuse_delete
    stray, kept = [], []
    for entry in Payroll.query.order_by(Payroll.id).all():
        try:
            refuse_bad_period(entry.month, entry.year)
            continue
        except PayrollRefused:
            pass
        row = {'id': entry.id, 'employee_id': entry.employee_id, 'month': entry.month, 'year': entry.year,
               'status': entry.status, 'net_salary': entry.net_salary}
        try:
            refuse_delete(entry)                 # pending, no accrual, no voucher
            stray.append(row)
        except PayrollRefused as refused:
            kept.append({**row, 'why': refused.message})
    plan = {'removed': stray, 'kept': kept}
    if dry_run or not stray:
        return plan
    for row in stray:
        db.session.delete(db.session.get(Payroll, row['id']))
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='payroll', entity_id=stray[0]['id'],
                            success=True, details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
