"""A payment voucher cancelled reopens the document it paid (PAYROLL-4; the owner, 1 Nov 2026).

On the 31 Oct copy two bonuses of يوسف الشعبي (#19, #51, 6,440) said «paid»
while their payment vouchers BPAY-19 and BPAY-51 had been cancelled on 6 Aug:
the books owed them, the bonuses did not. A salary's voucher was the same: the
payroll laws say «يُلغى السند أولًا إن كان خطأ», but cancelling it left the entry
paid. The owner: «الصحيح هو ما في الدفاتر». Asked by the voucher cancellation
(routes/vouchers.cancel_voucher), after its entry is reversed:

  - a bonus's payment voucher (reference 'bonus', payment): the bonus is
    approved and unpaid again;
  - a salary's voucher (reference 'payroll'): the entry is approved again, its
    bonuses with it, and its run is no longer paid;
  - a final settlement's voucher (reference 'eos_settlement', EMP-5):
    the settlement is approved again, the bonuses it paid unpaid.

tests/test_voucher_cancel_reopens_its_document.py.
"""
from __future__ import annotations

from models import EmployeeBonus, EmployeeTermination, Payroll, db


def reopen(voucher) -> None:
    """Caller commits."""
    if voucher.reference_type == 'bonus' and voucher.voucher_type == 'payment' and voucher.reference_id:
        bonus = db.session.get(EmployeeBonus, int(voucher.reference_id))
        if bonus is not None and bonus.status == 'paid':
            bonus.status, bonus.paid_at, bonus.paid_by, bonus.payment_reference = 'approved', None, None, None
    if voucher.reference_type == 'payroll' and voucher.reference_id:
        entry = db.session.get(Payroll, int(voucher.reference_id))
        if entry is not None and entry.voucher_id == voucher.id:
            entry.voucher_id, entry.paid_date, entry.status = None, None, 'approved'
            from services.payroll_payment import _mark_gold, _mark_kept
            _mark_kept(entry, 0.0)               # what it kept is owed again with the rest (PAY-SPLIT)
            _mark_gold(entry, None)              # and the gold it took is owed again (PAY-GOLD)
            for bonus in EmployeeBonus.query.filter_by(payroll_id=entry.id, status='paid'):
                bonus.status, bonus.paid_at, bonus.paid_by, bonus.payment_reference = 'approved', None, None, None
            if entry.run is not None and entry.run.status == 'paid':
                entry.run.status = 'approved'
    if voucher.reference_type == 'eos_settlement' and voucher.reference_id:
        termination = db.session.get(EmployeeTermination, int(voucher.reference_id))
        if termination is not None and termination.voucher_id == voucher.id:
            termination.voucher_id, termination.status, termination.paid_at = None, 'approved', None
            for bonus in EmployeeBonus.query.filter_by(employee_id=termination.employee_id, status='paid',
                                                       payment_reference=voucher.voucher_number):
                bonus.status, bonus.paid_at, bonus.paid_by, bonus.payment_reference = 'approved', None, None, None
    db.session.flush()
