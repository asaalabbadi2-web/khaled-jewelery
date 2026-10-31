"""A salary paid by its voucher -- one entry or a run's batch (PAYROLL-1 law 5, PAYROLL-2 M2b).

Moved from the mark-paid route as it was, so the run's batch pays by the same
hand: the voucher debits the employee's salary payable by the net and credits
the safe by what leaves it, and his advance by what is deducted from it; it is
born approved and posted (APPROVED-ENTRY-001). Only an approved entry is paid,
its accrual written first if it has none (services/payroll_laws).
"""
from __future__ import annotations

from models import Account, Employee, Voucher, VoucherAccountLine, db
from services.payroll_laws import PayrollRefused, ensure_accrual


def pay(entry, *, payment_account_id, paid_date, advance_deduction=0.0, by: str, now) -> None:
    """Paid by its voucher; a paid entry is left as it is. Caller commits."""
    if entry.voucher_id:
        return
    ensure_accrual(entry, by=by)
    employee = db.session.get(Employee, entry.employee_id)
    if employee is None:
        raise PayrollRefused('الموظف غير موجود')
    try:
        advance_deduction = float(advance_deduction or 0.0)
    except (TypeError, ValueError):
        raise PayrollRefused('خصم السلفة رقم') from None
    net = float(entry.net_salary or 0.0)
    if advance_deduction < 0:
        raise PayrollRefused('خصم السلفة لا يكون سالبًا')
    if round(advance_deduction - net, 2) > 0:
        raise PayrollRefused('خصم السلفة يزيد على صافي الراتب')
    if round(advance_deduction, 2) > 0 and not employee.account_id:
        raise PayrollRefused(f'لا يمكن خصم السلفة: الموظف «{employee.name}» ليس له حساب سلف مرتبط. '
                             'اربطه من شاشة الموظفين، أو اترك خصم السلفة صفرًا.')

    from accounting.mappings import AccountNotMapped, get_account_id_for_mapping
    from accounting.voucher_engine import _append_safe_transactions_for_voucher, post_entry_of_approved_voucher
    from services.employee_accounts import ensure_payable_account
    try:
        salary_account_id = int(ensure_payable_account(employee, 'salary_payable', by=by).id)
    except AccountNotMapped as missing:
        raise PayrollRefused(str(missing)) from None
    if payment_account_id:
        payment_account = db.session.get(Account, int(payment_account_id))
        if payment_account is None:
            raise PayrollRefused(f'حساب الدفع غير موجود (ID: {payment_account_id})')
    else:
        # The cash role, mapped -- the first account whose number began with
        # 100 or whose name held «صندوق» was the scrap box (1310002) on the
        # production copy (CHART-002).
        cash_id = get_account_id_for_mapping('افتراضي', 'cash')
        payment_account = db.session.get(Account, cash_id) if cash_id else None
        if payment_account is None:
            raise PayrollRefused('لا حساب نقدية مربوط (افتراضي / cash) ولا حساب دفع محدد')

    voucher = Voucher(voucher_number=_next_number(entry), voucher_type='payment', date=paid_date,
                      description=f'صرف راتب {employee.name} - {entry.month}/{entry.year}',
                      status='pending', created_by=by, party_type='other', party_name=employee.name,
                      reference_type='payroll', reference_id=int(entry.id),
                      reference_number=f'{entry.year}-{entry.month:02d}')
    db.session.add(voucher)
    db.session.flush()

    cash_paid = max(0.0, net - advance_deduction)
    if round(cash_paid, 2) > 0:
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=payment_account.id,
                                          line_type='credit', amount_type='cash', amount=cash_paid,
                                          description=f'صرف راتب {employee.name} - {payment_account.name}'))
    db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=salary_account_id, line_type='debit',
                                      amount_type='cash', amount=net,
                                      description=f'راتب {entry.month}/{entry.year}'))
    if round(advance_deduction, 2) > 0:
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=int(employee.account_id),
                                          line_type='credit', amount_type='cash', amount=advance_deduction,
                                          description=f'خصم سلفة من راتب {employee.name}'))

    journal_entry = post_entry_of_approved_voucher(voucher, posted_by=by)
    voucher.status = 'approved'
    voucher.approved_at = now
    voucher.approved_by = by
    voucher.journal_entry_id = journal_entry.id
    _append_safe_transactions_for_voucher(voucher, created_by=by)

    entry.voucher_id = voucher.id
    entry.paid_date = paid_date
    entry.status = 'paid'
    # its bonuses, moved into its net by the run's accrual, are paid by it (PAYROLL-4)
    from models import EmployeeBonus
    for bonus in EmployeeBonus.query.filter_by(payroll_id=entry.id, status='approved'):
        bonus.status, bonus.paid_at, bonus.paid_by = 'paid', now, by
        bonus.payment_reference = voucher.voucher_number


def _next_number(entry) -> str:
    prefix = f'PAY-{entry.year}-{entry.month:02d}'
    latest = (Voucher.query.filter(Voucher.voucher_number.like(f'{prefix}%'))
              .order_by(Voucher.voucher_number.desc()).first())
    try:
        sequence = int(latest.voucher_number.split('-')[-1]) + 1 if latest else 1
    except (ValueError, IndexError):
        sequence = 1
    return f'{prefix}-{sequence:04d}'
