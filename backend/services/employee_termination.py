"""An employee's end of service and its final settlement (EMP-5, ش5).

The owner, 1 Nov 2026: «عند إنهاء الخدمة: هل يحسب النظام التسوية النهائية
ويقيّدها؟ نعم» -- «اودع وابدأ». Stopping an employee was a flag: nothing was
settled, his balances and his advance left as they were.

  1. a termination is its last day and reason; previewed before it is approved;
  2. the end-of-service award by the reason: whole (ended by the employer,
     the contract's end, agreement, death -- art. 84, 87), by the policy's
     shares for a resignation (art. 85), none for art. 80 -- the shares and
     years the owner's; unset, a resignation is not settled;
  3. his paid accruing leave left is paid, its days at the gross by the
     policy's day divisor;
  4. approved with ONE entry: the provision brought to the award (Dr/Cr the
     end-of-service expense, his end-of-service payable) and the leave's pay
     (Dr salary expense / Cr his salary payable); he is stopped with his
     users, his custody said, his advance plans ended;
  5. paid by ONE voucher at what the books owe him then -- his salary,
     bonuses, commissions and end-of-service payables, less his advance --
     not while a run line of his is approved and unpaid (it would be paid
     twice); his approved bonuses are paid with it;
  6. cancelled while unpaid: its entry reversed, he is active again (his
     users stay stopped); a paid one is not cancelled.
His last month's salary is his run's: the run prorates it by his last day.
tests/test_employee_termination.py.
"""
from __future__ import annotations

import json
from datetime import date

from models import (Account, Employee, EmployeeBonus, EmployeeTermination, JournalEntry, LeaveType, Payroll,
                    PayrollRun, Voucher, VoucherAccountLine, db)
from services.payroll_laws import PayrollRefused

ENTRY = 'eos_settlement'           # voucher.reference_type is 20 wide
REVERSAL = 'eos_settlement_reversal'
SNAPSHOT_SCHEMA_VERSION = 1
WHOLE = ('employer_ended', 'contract_end', 'mutual', 'death')
REASONS = WHOLE + ('resignation', 'art_80')
OWED_ROLES = ('salary_payable', 'bonus_payable', 'commission_payable', 'eos_payable')


def _credit(account_id) -> float:
    from services.live_balances import live_balances_by_account_ids
    if not account_id:
        return 0.0
    return round(-float(live_balances_by_account_ids([account_id]).get(account_id, {}).get('cash', 0.0)), 2) + 0.0


def _share(reason: str, years: float) -> float:
    """Law 2: the award's share by the reason."""
    from services.payroll_policy import PayrollPolicyNotSet, require
    if reason in WHOLE:
        return 1
    if reason == 'art_80':
        return 0
    try:
        if years < float(require('eos_resign_min_years')):
            return 0
        if years < float(require('eos_resign_tier1_years')):
            return float(require('eos_resign_tier1_share'))
        if years < float(require('eos_resign_tier2_years')):
            return float(require('eos_resign_tier2_share'))
    except PayrollPolicyNotSet as unset:
        raise PayrollRefused('نسب مكافأة الاستقالة غير مضبوطة (المادة 85): تُضبط في «سياسة الرواتب». ' + unset.message,
                             'payroll_policy_not_set') from None
    return 1


def preview(employee, data: dict) -> dict:
    """Laws 1-3, nothing written."""
    from services.employee_access import custody_of
    from services.employee_accounts import employee_account
    from services.employee_leave import balance
    from services.payroll_eos import booked, entitlement, service_years, wage_of
    from services.payroll_policy import PayrollPolicyNotSet, require, structure_on
    reason = data.get('reason')
    if reason not in REASONS:
        raise PayrollRefused('سبب الإنهاء غير معروف')
    try:
        last_day = date.fromisoformat(str(data.get('last_day')))
    except ValueError:
        raise PayrollRefused('آخر يوم عمل: تاريخ YYYY-MM-DD') from None
    if employee.hire_date is None:
        raise PayrollRefused('لا تاريخ تعيين للموظف: لا تُحسب مكافأة نهاية خدمته')
    if last_day < employee.hire_date:
        raise PayrollRefused('آخر يوم قبل تاريخ التعيين')
    if employee.terminations.filter(EmployeeTermination.status != 'cancelled').first() is not None:
        raise PayrollRefused('للموظف إنهاء خدمة قائم')
    structure = structure_on(employee.id, last_day)
    if structure is None:
        raise PayrollRefused('لا هيكل راتب للموظف في آخر يوم: لا يُعرف أجره')
    try:
        wage = wage_of(structure)
        days, whole_award = entitlement(employee.hire_date, last_day, wage)
        divisor = int(require('day_divisor'))
    except PayrollPolicyNotSet as unset:
        raise PayrollRefused(unset.message, 'payroll_policy_not_set') from None
    years = service_years(employee.hire_date, last_day)
    share = _share(reason, years)
    award = round(whole_award * share, 2)
    held = booked(employee)

    leave_rows, leave_pay = [], 0.0
    daily = structure.gross / divisor
    for kind in LeaveType.query.filter_by(is_active=True, paid=True, accrues=True).order_by(LeaveType.id):
        left = balance(employee, kind, last_day)
        if left is not None and left > 0:
            amount = round(left * daily, 2)
            leave_rows.append({'type': kind.name, 'days': left, 'amount': amount})
            leave_pay = round(leave_pay + amount, 2)

    owed = {role: _credit(getattr(employee_account(employee, role), 'id', None)) for role in OWED_ROLES}
    advance = round(-_credit(employee.account_id), 2) + 0.0
    owed_after = {**owed, 'eos_payable': award,
                  'salary_payable': round(owed['salary_payable'] + leave_pay, 2)}
    gross_owed = round(sum(owed_after.values()), 2)
    return {'snapshot_schema_version': SNAPSHOT_SCHEMA_VERSION, 'last_day': last_day.isoformat(),
            'reason': reason, 'service_days': days, 'service_years': round(years, 4), 'wage': wage,
            'eos': {'whole': whole_award, 'share': share, 'award': award, 'booked': held,
                    'adjustment': round(award - held, 2)},
            'leave': {'rows': leave_rows, 'daily_wage': round(daily, 2), 'amount': leave_pay},
            'owed_now': owed, 'owed_after': owed_after, 'advance': advance,
            'net': round(gross_owed - advance, 2),
            'custody': custody_of(employee)}


def approve(employee_id: int, data: dict, *, by: str, now) -> tuple[EmployeeTermination, dict]:
    """Law 4. Caller commits."""
    from services.employee_access import stop
    employee = db.session.get(Employee, employee_id)
    if employee is None:
        raise PayrollRefused('الموظف غير موجود')
    settlement = preview(employee, data)
    termination = EmployeeTermination(employee_id=employee.id, last_day=date.fromisoformat(settlement['last_day']),
                                      reason=settlement['reason'], notes=data.get('notes'), status='approved',
                                      settlement=json.dumps(settlement, ensure_ascii=False), created_by=by)
    db.session.add(termination)
    db.session.flush()
    savepoint = db.session.begin_nested()
    try:
        entry = _write_entry(termination, employee, settlement, by=by, now=now)
        termination.journal_entry_id = entry.id if entry is not None else None
        employee.termination_date = termination.last_day
        for plan in employee.advance_plans.filter_by(status='active'):
            plan.status = 'cancelled'
        stopped = stop(employee, by=by, now=now) if employee.is_active else {}
        db.session.flush()
    except PayrollRefused:
        savepoint.rollback()
        raise
    savepoint.commit()
    return termination, stopped


def _write_entry(termination, employee, settlement, *, by: str, now):
    from accounting.balances import _recalculate_account_balances_for_accounts
    from accounting.mappings import AccountNotMapped, DEFAULT_MAPPING_OPERATION_TYPE, require_account
    from dual_system_helpers import create_dual_journal_entry, verify_dual_balance
    from services.employee_accounts import SALARY_EXPENSE, ensure_payable_account, parent_account
    adjustment, leave_pay = settlement['eos']['adjustment'], settlement['leave']['amount']
    if not adjustment and not leave_pay:
        return None
    lines = []                                  # (account id, debit, credit, description)
    try:
        if adjustment:
            expense = require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'eos_expense')
            payable = int(ensure_payable_account(employee, 'eos_payable', by=by).id)
            amount = abs(adjustment)
            pair = ((expense, amount, 0), (payable, 0, amount)) if adjustment > 0 else \
                ((payable, amount, 0), (expense, 0, amount))
            lines += [(a, d, c, f'مكافأة نهاية خدمة {employee.name}') for a, d, c in pair]
        if leave_pay:
            lines.append((parent_account(SALARY_EXPENSE).id, leave_pay, 0, f'بدل إجازة {employee.name}'))
            lines.append((int(ensure_payable_account(employee, 'salary_payable', by=by).id), 0, leave_pay,
                          f'بدل إجازة {employee.name}'))
    except AccountNotMapped as missing:
        raise PayrollRefused(str(missing)) from None
    description = f'تسوية نهاية خدمة {employee.name} ({termination.last_day})'
    entry = JournalEntry(date=now, description=description, entry_type='عادي', reference_type=ENTRY,
                         reference_id=int(termination.id), created_by=by, is_posted=True, posted_at=now, posted_by=by)
    db.session.add(entry)
    db.session.flush()
    for account_id, debit, credit, label in lines:
        create_dual_journal_entry(journal_entry_id=entry.id, account_id=account_id, cash_debit=debit,
                                  cash_credit=credit, description=label)
    if not verify_dual_balance(entry.id).get('balanced', True):
        raise PayrollRefused('لم يتوازن قيد التسوية')
    _recalculate_account_balances_for_accounts({a for a, _, _, _ in lines})
    return entry


def pay(termination, data: dict, *, by: str, now) -> Voucher:
    """Law 5: one voucher, at what the books owe him now. Caller commits."""
    from accounting.voucher_engine import _append_safe_transactions_for_voucher, post_entry_of_approved_voucher
    from services.employee_accounts import employee_account
    if termination.status != 'approved':
        raise PayrollRefused('تُصرف تسوية معتمدة غير مصروفة')
    employee = termination.employee
    from services.payroll_payment import settled
    # a line kept whole on his salary payable (PAY-SPLIT) is owed in the books,
    # and the settlement pays what the books owe: it is not «unpaid»
    unpaid_line = next((line for line in Payroll.query.join(PayrollRun, Payroll.payroll_run_id == PayrollRun.id)
                        .filter(Payroll.employee_id == employee.id, Payroll.status == 'approved',
                                Payroll.voucher_id.is_(None))
                        if not settled(line)), None)
    if unpaid_line is not None:
        raise PayrollRefused(f'راتب {unpaid_line.month}/{unpaid_line.year} معتمد غير مصروف: يُصرف من مسيره أولًا، '
                             'وإلا صُرف مرتين.')
    account = db.session.get(Account, int(data['payment_account_id'])) if data.get('payment_account_id') else None
    if account is None:
        raise PayrollRefused('حساب الصرف مطلوب')
    try:
        paid_date = date.fromisoformat(str(data.get('paid_date') or now.date().isoformat()))
    except ValueError:
        raise PayrollRefused('تاريخ الصرف YYYY-MM-DD') from None
    debits = []
    for role in OWED_ROLES:
        payable = employee_account(employee, role)
        owed = _credit(payable.id) if payable is not None else 0.0
        if owed > 0:
            debits.append((payable.id, owed))
    gross = round(sum(amount for _, amount in debits), 2)
    advance = round(-_credit(employee.account_id), 2) + 0.0
    deducted = round(min(max(advance, 0.0), gross), 2)
    net = round(gross - deducted, 2)
    if gross <= 0:
        raise PayrollRefused('لا مستحق له في الدفاتر يُصرف')
    number = f'EOS-{termination.id}'
    paid_before = Voucher.query.filter(Voucher.voucher_number.like(f'{number}%')).count()
    if paid_before:                               # its voucher cancelled, paid again
        number = f'{number}-{paid_before + 1}'
    voucher = Voucher(voucher_number=number, voucher_type='payment', date=paid_date,
                      description=f'تسوية نهاية خدمة {employee.name}', status='pending', created_by=by,
                      party_type='other', party_name=employee.name, reference_type=ENTRY,
                      reference_id=int(termination.id))
    db.session.add(voucher)
    db.session.flush()
    for account_id, amount in debits:
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=account_id, line_type='debit',
                                          amount_type='cash', amount=amount, description='تسوية نهاية الخدمة'))
    if deducted > 0:
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=int(employee.account_id),
                                          line_type='credit', amount_type='cash', amount=deducted,
                                          description='خصم السلف من التسوية'))
    if net > 0:
        db.session.add(VoucherAccountLine(voucher_id=voucher.id, account_id=account.id, line_type='credit',
                                          amount_type='cash', amount=net, description=f'صرف التسوية - {account.name}'))
    journal = post_entry_of_approved_voucher(voucher, posted_by=by)
    voucher.status, voucher.approved_at, voucher.approved_by, voucher.journal_entry_id = 'approved', now, by, journal.id
    _append_safe_transactions_for_voucher(voucher, created_by=by)
    for bonus in EmployeeBonus.query.filter_by(employee_id=employee.id, status='approved'):
        bonus.status, bonus.paid_at, bonus.paid_by, bonus.payment_reference = 'paid', now, by, voucher.voucher_number
    termination.voucher_id, termination.status, termination.paid_at = voucher.id, 'paid', now
    db.session.flush()
    return voucher


def cancel(termination, *, by: str, now) -> None:
    """Law 6. Caller commits."""
    from services.employee_access import record, snapshot
    from services.payroll_laws import reverse_entry
    if termination.status == 'paid':
        raise PayrollRefused('صُرفت التسوية: لا تُلغى. يُلغى سند صرفها أولًا إن كان خطأ.')
    if termination.status == 'cancelled':
        return
    if termination.journal_entry_id:
        entry = db.session.get(JournalEntry, termination.journal_entry_id)
        reverse_entry(entry, reference_type=REVERSAL, reference_id=int(termination.id),
                      description=f'عكس تسوية نهاية خدمة (إلغاء #{termination.id})', by=by, now=now)
    employee = termination.employee
    before = snapshot(employee)
    employee.is_active, employee.termination_date = True, None
    record(employee, action='cancel_termination', before=before, by=by, now=now)
    termination.status = 'cancelled'
    db.session.flush()
