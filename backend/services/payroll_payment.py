"""A salary paid by its voucher -- one entry or a run's batch (PAYROLL-1 law 5, PAYROLL-2 M2b).

Moved from the mark-paid route as it was, so the run's batch pays by the same
hand: the voucher debits the employee's salary payable by the net and credits
the safe by what leaves it, and his advance by what is deducted from it; it is
born approved and posted (APPROVED-ENTRY-001). Only an approved entry is paid,
its accrual written first if it has none (services/payroll_laws).

Paid part by bank, part by cash, part kept (PAY-SPLIT; the owner, 2 Nov 2026:
«مبلغ ثابت، والباقي بالأخرى» and «أمانة في ذمته، تُصرف لاحقًا»): one voucher
still, a credit for each way money leaves; what is not paid is kept on his
salary payable, owed to him -- said on the line (`kept_owed`), never moved.
Nothing paid at all writes no voucher: the line is kept whole.
"""
from __future__ import annotations

import json

from models import Account, Employee, Voucher, VoucherAccountLine, db
from services.payroll_laws import PayrollRefused, ensure_accrual


def kept_owed(entry) -> float:
    """What of the line was kept on his salary payable at its payment."""
    try:
        return round(float(json.loads(entry.breakdown or '{}').get('kept_owed') or 0.0), 2)
    except (TypeError, ValueError):
        return 0.0


def settled(entry) -> bool:
    """Paid by its voucher, or kept whole on his salary payable."""
    return bool(entry.voucher_id) or (kept_owed(entry) > 0 and round(kept_owed(entry) - float(entry.net_salary or 0), 2) == 0)


def _mark_kept(entry, amount: float) -> None:
    if amount <= 0 and not entry.breakdown:
        return                                       # an entry before the runs keeps its none
    breakdown = json.loads(entry.breakdown or '{}')
    if amount > 0:
        breakdown['kept_owed'] = round(amount, 2)
    else:
        breakdown.pop('kept_owed', None)
    entry.breakdown = json.dumps(breakdown, ensure_ascii=False)


def pay(entry, *, payment_account_id=None, parts=None, paid_date, advance_deduction=0.0, by: str, now) -> None:
    """Paid by its voucher; a paid entry is left as it is. Caller commits.

    `parts`: [(account_id, amount)] -- each way money leaves; absent, the whole
    (net less the advance) from `payment_account_id` (or the mapped cash)."""
    if settled(entry):
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
    payable = round(max(0.0, net - advance_deduction), 2)
    if parts is None:
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
        legs = [(payment_account, payable)]
    else:
        legs = []
        for account_id, amount in parts:
            try:
                amount = round(float(amount or 0.0), 2)
            except (TypeError, ValueError):
                raise PayrollRefused('مبلغ الصرف رقم') from None
            if amount < 0:
                raise PayrollRefused('مبلغ الصرف لا يكون سالبًا')
            if amount == 0:
                continue
            account = db.session.get(Account, int(account_id)) if account_id else None
            if account is None:
                raise PayrollRefused(f'حساب الصرف غير محدد لمبلغ {amount:,.2f} من راتب {employee.name}')
            legs.append((account, amount))
    paid = round(sum(amount for _, amount in legs), 2)
    if round(paid - payable, 2) > 0:
        raise PayrollRefused(f'ما يُصرف لـ {employee.name} ({paid:,.2f}) يزيد على صافيه ({payable:,.2f})',
                             'pay_beyond_net')
    kept = round(payable - paid, 2)
    if paid == 0 and round(advance_deduction, 2) == 0:
        _mark_kept(entry, kept)                      # nothing leaves: kept whole, no voucher
        return

    voucher = Voucher(voucher_number=_next_number(entry), voucher_type='payment', date=paid_date,
                      description=f'صرف راتب {employee.name} - {entry.month}/{entry.year}',
                      status='pending', created_by=by, party_type='other', party_name=employee.name,
                      reference_type='payroll', reference_id=int(entry.id),
                      reference_number=f'{entry.year}-{entry.month:02d}')
    db.session.add(voucher)
    db.session.flush()

    for account, amount in legs:
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=account.id,
                                          line_type='credit', amount_type='cash', amount=amount,
                                          description=f'صرف راتب {employee.name} - {account.name}'))
    db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=salary_account_id, line_type='debit',
                                      amount_type='cash', amount=round(paid + advance_deduction, 2),
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
    _mark_kept(entry, kept)
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


def owed_salary(employee) -> float:
    """What his salary payable holds for him in the books (PAY-SPLIT)."""
    from services.employee_accounts import employee_account
    from services.employee_termination import _credit
    account = employee_account(employee, 'salary_payable')
    return _credit(account.id) if account is not None else 0.0


def pay_owed(employee, *, amount, payment_account_id, paid_date, by: str, now):
    """What was kept owed to him, paid -- all or part, by its voucher; never more
    than his salary payable holds (the owner, 2 Nov 2026: «أمانة في ذمته، تُصرف
    لاحقًا»). Caller commits."""
    from accounting.voucher_engine import _append_safe_transactions_for_voucher, post_entry_of_approved_voucher
    from services.employee_accounts import employee_account
    try:
        amount = round(float(amount or 0.0), 2)
    except (TypeError, ValueError):
        raise PayrollRefused('المبلغ رقم') from None
    if amount <= 0:
        raise PayrollRefused('المبلغ موجب')
    owed = owed_salary(employee)
    if amount > owed:
        raise PayrollRefused(f'المستحق له في ذمة رواتبه {owed:,.2f}: لا يُصرف أكثر منه', 'pay_beyond_owed')
    account = db.session.get(Account, int(payment_account_id)) if payment_account_id else None
    if account is None:
        raise PayrollRefused('حساب الصرف مطلوب')
    salary_account = employee_account(employee, 'salary_payable')
    prefix = f'PAYK-{paid_date.year}'
    latest = (Voucher.query.filter(Voucher.voucher_number.like(f'{prefix}-%'))
              .order_by(Voucher.voucher_number.desc()).first())
    try:
        sequence = int(latest.voucher_number.split('-')[-1]) + 1 if latest else 1
    except (ValueError, IndexError):
        sequence = 1
    voucher = Voucher(voucher_number=f'{prefix}-{sequence:04d}', voucher_type='payment', date=paid_date,
                      description=f'صرف مستحق رواتب {employee.name}', status='pending', created_by=by,
                      party_type='other', party_name=employee.name,
                      reference_type='salary_owed', reference_id=int(employee.id))
    db.session.add(voucher)
    db.session.flush()
    db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=account.id, line_type='credit',
                                      amount_type='cash', amount=amount,
                                      description=f'صرف مستحق رواتب {employee.name} - {account.name}'))
    db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=salary_account.id, line_type='debit',
                                      amount_type='cash', amount=amount, description='مستحق رواتب لم يُصرف'))
    journal_entry = post_entry_of_approved_voucher(voucher, posted_by=by)
    voucher.status, voucher.approved_at, voucher.approved_by = 'approved', now, by
    voucher.journal_entry_id = journal_entry.id
    _append_safe_transactions_for_voucher(voucher, created_by=by)
    return voucher

