"""The bonuses' statuses put right by the books (PAYROLL-4; the owner, 1 Nov 2026: «الصحيح هو ما في الدفاتر»).

On the 31 Oct copy the bonuses and their accounts disagreed (BONUS-BOOKS-1):
  - مسعد #52 (2,512.50) «approved» -- paid by the manual entry JE-2026-05473,
    his account owes nothing;
  - يوسف #19, #51 (6,440) «paid» -- their vouchers BPAY-19, BPAY-51 cancelled
    on 6 Aug, his account still owes them (the cancellation never reopened a
    bonus; it does now, services/voucher_cancel_documents).
Per employee, by his bonus account (counted lines):
  1. bonuses «paid» whose payment voucher was cancelled are approved again
     when what the account owes beyond his approved is their sum -- the one
     set of them that makes it, else none is guessed (يوسف: 6,440 beyond, #19
     and #51 of #11, #19, #51); one paid otherwise (عبدالله #16: BPAY-16
     cancelled, two vouchers paid it; يوسف #11) is kept paid;
  2. when the account owes nothing, his approved bonuses are paid -- in the
     books, outside the bonus screen;
  3. anything else is the run's (one bonus owed in part is paid at what the
     books owe) or held -- listed, not touched.
dry_run (the default) writes nothing; an audit row names what changed.
"""
import json
from itertools import combinations

from models import AuditLog, Employee, EmployeeBonus, Voucher, db

ACTION = 'repair_bonus_status_from_books'
BOOKS_REFERENCE = 'الدفاتر (BONUS-BOOKS-1)'


def _cancelled_payment(bonus) -> bool:
    return (Voucher.query.filter_by(reference_type='bonus', reference_id=bonus.id, voucher_type='payment')
            .filter(Voucher.status == 'cancelled').first() is not None
            and Voucher.query.filter_by(reference_type='bonus', reference_id=bonus.id, voucher_type='payment')
            .filter(Voucher.status != 'cancelled').first() is None)


def _the_one_set(bonuses, target: float):
    """The one set of the bonuses whose amounts sum to the target -- or None."""
    found = [subset for size in range(1, len(bonuses) + 1) for subset in combinations(bonuses, size)
             if round(sum(b.amount or 0.0 for b in subset) - target, 2) == 0]
    return list(found[0]) if len(found) == 1 else None


def settle(*, by: str, now, dry_run: bool = True) -> dict:
    from services.bonus_accounts import employee_bonus_account, owed_in_books
    plan = {'reopened': [], 'paid_in_books': [], 'kept_paid': [], 'left': []}
    for employee in Employee.query.order_by(Employee.id):
        if employee_bonus_account(employee) is None:
            continue
        owed = owed_in_books(employee)
        approved = (EmployeeBonus.query.filter_by(employee_id=employee.id, status='approved', payroll_id=None)
                    .order_by(EmployeeBonus.id).all())
        approved_total = round(sum(b.amount or 0.0 for b in approved), 2)
        cancelled = [b for b in EmployeeBonus.query.filter_by(employee_id=employee.id, status='paid')
                     .order_by(EmployeeBonus.id) if _cancelled_payment(b)]
        beyond = round(owed - approved_total, 2)
        reopen = _the_one_set(cancelled, beyond) if cancelled and beyond > 0 else None
        if reopen:
            plan['reopened'] += [{'employee': employee.name, 'bonus_id': b.id, 'amount': b.amount} for b in reopen]
            if not dry_run:
                for bonus in reopen:
                    bonus.status, bonus.paid_at, bonus.paid_by, bonus.payment_reference = 'approved', None, None, None
            approved_total = round(approved_total + sum(b.amount or 0.0 for b in reopen), 2)
        for bonus in cancelled:
            if not reopen or bonus not in reopen:
                plan['kept_paid'].append({'employee': employee.name, 'bonus_id': bonus.id, 'amount': bonus.amount,
                                          'why': 'سند صرفها ملغى، والدفاتر تقول إنها صُرفت بغيره'})
        if approved and owed <= 0:
            plan['paid_in_books'] += [{'employee': employee.name, 'bonus_id': b.id, 'amount': b.amount}
                                      for b in approved]
            if not dry_run:
                for bonus in approved:
                    bonus.status, bonus.paid_at, bonus.paid_by = 'paid', now, by
                    bonus.payment_reference = BOOKS_REFERENCE
        elif approved and approved_total > owed:
            plan['left'].append({'employee': employee.name, 'owed_in_books': owed, 'approved_unpaid': approved_total,
                                 'why': 'يصرفها المسير بما تقوله الدفاتر' if len(approved) == 1
                                        else 'محجوزة: عدّة مكافآت والدفاتر تستحق أقل من مجموعها'})
    changed = plan['reopened'] or plan['paid_in_books']
    if dry_run or not changed:
        return plan
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='employee_bonus',
                            entity_id=(plan['reopened'] or plan['paid_in_books'])[0]['bonus_id'],
                            success=True, details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
