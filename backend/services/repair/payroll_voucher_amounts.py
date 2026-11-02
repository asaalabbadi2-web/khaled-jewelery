"""Salary vouchers' amount on the vouchers' list, from their own lines (the owner, 2 Nov 2026).

«مبلغ سند صرف الرواتب لا يظهر في قائمة السندات»: a salary's payment voucher
(reference payroll), a later payment of what was kept owed (salary_owed) and
an end-of-service settlement's (eos_settlement) were written with their lines
and their entry, their header's amount left 0 -- the list reads the header. On
the 2 Nov copy: 57, every one paid since PAYROLL-1. Their cause is mended
(services/payroll_payment, services/employee_termination write the amount
now); this writes the amount of the ones already saved: the sum of their
debit lines -- what left and what was deducted, the books' own -- and whose
it is. Nothing of the books is touched: the lines and the entry stay.
dry_run (the default) writes nothing; an audit row names each one written.
"""
import json

from models import AuditLog, Payroll, Voucher, VoucherAccountLine, db

ACTION = 'repair_payroll_voucher_amounts'
REFERENCES = ('payroll', 'salary_owed', 'eos_settlement')


def write_amounts(*, by: str, dry_run: bool = True) -> dict:
    from models import EmployeeTermination
    rows = []
    for voucher in (Voucher.query.filter(Voucher.reference_type.in_(REFERENCES))
                    .filter(db.or_(Voucher.amount_cash.is_(None), Voucher.amount_cash == 0))
                    .order_by(Voucher.id)):
        whole = round(sum(float(line.amount or 0.0) for line in
                          VoucherAccountLine.query.filter_by(voucher_id=voucher.id, line_type='debit')), 2)
        if whole <= 0:
            continue
        employee_id = voucher.employee_id
        if employee_id is None and voucher.reference_id:
            if voucher.reference_type == 'payroll':
                entry = db.session.get(Payroll, int(voucher.reference_id))
                employee_id = entry.employee_id if entry is not None else None
            elif voucher.reference_type == 'salary_owed':
                employee_id = int(voucher.reference_id)
            else:
                termination = db.session.get(EmployeeTermination, int(voucher.reference_id))
                employee_id = termination.employee_id if termination is not None else None
        rows.append({'id': voucher.id, 'voucher_number': voucher.voucher_number, 'status': voucher.status,
                     'amount_cash': whole, 'employee_id': employee_id})
    plan = {'written': rows, 'total': round(sum(r['amount_cash'] for r in rows), 2)}
    if dry_run or not rows:
        return plan
    for row in rows:
        voucher = db.session.get(Voucher, row['id'])
        voucher.amount_cash = row['amount_cash']
        if voucher.employee_id is None:
            voucher.employee_id = row['employee_id']
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='voucher', entity_id=rows[0]['id'],
                            success=True, details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
