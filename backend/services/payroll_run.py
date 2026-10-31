"""A month's payroll, one document: drafted, reviewed, approved with one accrual, paid in a batch (PAYROLL-2, M2b).

The owner, 1 Nov 2026 («اودع وابدأ»). On the 31 Oct copy a month was five
entries keyed by hand, each approved and paid alone, its figure not the
employee file's. A run:

  1. is drafted from each employee's salary structure on the month's last
     day -- prorated by the policy's day divisor when he joined or left in it;
     an employee left out is said with his reason;
  2. is reviewed while a draft: additions and deductions, each with its label;
  3. is approved with ONE accrual for all its lines, or stays a draft; its
     policy is frozen on it;
  4. is cancelled whole: an approved one's accrual is reversed; one with a
     paid line is not cancelled;
  5. is paid in a batch, each line by its voucher (services/payroll_payment),
     from the bank or the cash the employee is paid by -- all or none.

One regular run a month. A line of a run is the run's: it is not approved,
cancelled or edited alone (services/payroll_laws). tests/test_payroll_run.py.
"""
from __future__ import annotations

import calendar
import json
from datetime import date

from models import Employee, JournalEntry, Payroll, PayrollRun, db
from services.payroll_laws import PayrollRefused, refuse_bad_period
from services.payroll_policy import policy, require, structure_on

RUN_ACCRUAL = 'payroll_run_accrual'
RUN_REVERSAL = 'payroll_run_accrual_reversal'
SNAPSHOT_SCHEMA_VERSION = 1


def _month_bounds(month: int, year: int) -> tuple[date, date]:
    return date(year, month, 1), date(year, month, calendar.monthrange(year, month)[1])


def _period(employee, first: date, last: date):
    start = max(employee.hire_date, first) if employee.hire_date else first
    end = min(employee.termination_date, last) if employee.termination_date else last
    return (start, end) if start <= end else None


def _standing_entry(employee_id: int, month: int, year: int):
    return (Payroll.query.filter(Payroll.employee_id == employee_id, Payroll.month == month,
                                 Payroll.year == year, Payroll.status != 'cancelled').first())


def open_run(month: int, year: int, kind: str = 'regular'):
    return (PayrollRun.query.filter(PayrollRun.month == month, PayrollRun.year == year,
                                    PayrollRun.kind == kind, PayrollRun.status != 'cancelled').first())


# ── 1. drafted ─────────────────────────────────────────────────────────────────

def generate(month, year, *, by: str) -> tuple[PayrollRun, list[dict]]:
    """A draft from the structures. Caller commits."""
    refuse_bad_period(month, year)
    month, year = int(month), int(year)
    if open_run(month, year) is not None:
        raise PayrollRefused(f'لشهر {month}/{year} مسير قائم: يُراجَع أو يُلغى، ولا يُنشأ ثانٍ',
                             'payroll_run_exists')
    divisor = int(require('day_divisor'))
    first, last = _month_bounds(month, year)
    run = PayrollRun(month=month, year=year, kind='regular', status='draft', created_by=by)
    db.session.add(run)
    db.session.flush()
    for employee in Employee.query.order_by(Employee.id):
        reason, period, structure = _eligibility(run, employee, first, last)
        if reason is None:
            _draft_line(run, employee, period, structure, first, last, divisor, by)
    db.session.flush()
    return run, left_out(run)


def left_out(run) -> list[dict]:
    """Each employee the run has no line for, and why -- an inactive one not
    employed in the month is not said."""
    first, last = _month_bounds(run.month, run.year)
    rows = []
    for employee in Employee.query.order_by(Employee.id):
        reason, _, _ = _eligibility(run, employee, first, last)
        reason = reason or 'removed'                  # eligible, its line removed from the draft
        if reason != 'in_the_run' and (employee.is_active or reason != 'not_employed'):
            rows.append({'employee_id': employee.id, 'name': employee.name, 'reason': reason})
    return rows


def _eligibility(run, employee, first: date, last: date):
    if run.entries.filter(Payroll.employee_id == employee.id).first() is not None:
        return 'in_the_run', None, None
    if not employee.is_active and not (employee.termination_date and employee.termination_date >= first):
        return 'not_employed', None, None
    period = _period(employee, first, last)
    if period is None:
        return 'not_employed', None, None
    if _standing_entry(employee.id, run.month, run.year) is not None:
        return 'has_an_entry', None, None
    structure = structure_on(employee.id, last)
    if structure is None:
        return 'no_structure', None, None
    return None, period, structure


def _draft_line(run, employee, period, structure, first: date, last: date, divisor: int, by: str) -> None:
    days = (period[1] - period[0]).days + 1
    whole = days == (last - first).days + 1
    share = 1 if whole else min(days, divisor) / divisor
    monthly = {'basic': structure.basic, 'housing': structure.housing, 'transport': structure.transport,
               'other_allowances': structure.other_allowances}
    earned = {key: round(value * share, 2) for key, value in monthly.items()}
    breakdown = {'snapshot_schema_version': SNAPSHOT_SCHEMA_VERSION, 'structure_id': structure.id,
                 'monthly': monthly, 'earned': earned, 'days': days, 'divisor': divisor, 'whole_month': whole,
                 'additions': [], 'deductions': []}
    entry = Payroll(employee_id=employee.id, month=run.month, year=run.year, payroll_run_id=run.id,
                    status='pending', created_by=by)
    _apply(entry, breakdown)
    db.session.add(entry)


def _apply(entry, breakdown: dict) -> None:
    earned = breakdown['earned']
    entry.basic_salary = earned['basic']
    entry.allowances = round(earned['housing'] + earned['transport'] + earned['other_allowances']
                             + sum(line['amount'] for line in breakdown['additions']), 2)
    entry.deductions = round(sum(line['amount'] for line in breakdown['deductions']), 2)
    entry.net_salary = round(entry.basic_salary + entry.allowances - entry.deductions, 2)
    entry.breakdown = json.dumps(breakdown, ensure_ascii=False)


# ── 2. reviewed ────────────────────────────────────────────────────────────────

def _refuse_unless_draft(run) -> None:
    if run.status != 'draft':
        raise PayrollRefused('المسير معتمد: لا يُعدَّل. يُلغى إن لم يُصرف منه شيء، ثم يُنشأ من جديد.')


def edit_line(entry, data: dict) -> None:
    """Additions and deductions of a draft's line, each with its label. Caller commits."""
    run = entry.run
    _refuse_unless_draft(run)
    breakdown = json.loads(entry.breakdown)
    for side in ('additions', 'deductions'):
        if side in data:
            breakdown[side] = [_labelled(line) for line in (data.get(side) or [])]
    if 'notes' in data:
        entry.notes = data.get('notes')
    _apply(entry, breakdown)
    if entry.net_salary < 0:
        raise PayrollRefused('الخصومات تزيد على المستحق: الصافي سالب')


def _labelled(line) -> dict:
    label = str((line or {}).get('label') or '').strip()
    if not label:
        raise PayrollRefused('لكل إضافة أو خصم سببه')
    try:
        amount = round(float(line.get('amount')), 2)
    except (TypeError, ValueError):
        raise PayrollRefused(f'{label}: المبلغ رقم') from None
    if amount <= 0:
        raise PayrollRefused(f'{label}: المبلغ موجب')
    return {'label': label, 'amount': amount}


def remove_line(entry) -> None:
    _refuse_unless_draft(entry.run)
    db.session.delete(entry)
    db.session.flush()


# ── 3. approved with one accrual ───────────────────────────────────────────────

def approve(run, *, by: str, now) -> None:
    """All its lines approved with one accrual, or the run stays a draft. Caller commits."""
    _refuse_unless_draft(run)
    lines = run.entries.order_by(Payroll.id).all()
    if not lines:
        raise PayrollRefused('المسير بلا أسطر')
    empty = [line.employee.name for line in lines if (line.net_salary or 0.0) <= 0]
    if empty:
        raise PayrollRefused('صافي الراتب صفر لـ: ' + '، '.join(empty))
    savepoint = db.session.begin_nested()
    try:
        _write_accrual(run, lines, by=by, now=now)
        for line in lines:
            line.status = 'approved'
        run.status = 'approved'
        run.approved_by, run.approved_at = by, now
        run.policy_snapshot = json.dumps(policy())
        db.session.flush()
    except PayrollRefused:
        savepoint.rollback()
        raise
    except Exception as exc:          # noqa: BLE001 -- the run stays a draft, the reason said
        savepoint.rollback()
        raise PayrollRefused(f'لم يُعتمد المسير لأن قيد استحقاقه لم يُكتب: {exc}') from None
    savepoint.commit()


def _write_accrual(run, lines, *, by: str, now) -> JournalEntry:
    from accounting.balances import _recalculate_account_balances_for_accounts
    from accounting.mappings import AccountNotMapped
    from dual_system_helpers import create_dual_journal_entry, verify_dual_balance
    from services.employee_accounts import SALARY_EXPENSE, ensure_payable_account, parent_account
    try:
        expense = parent_account(SALARY_EXPENSE)
        payables = [(line, int(ensure_payable_account(line.employee, 'salary_payable', by=by).id))
                    for line in lines]
    except AccountNotMapped as missing:
        raise PayrollRefused(str(missing)) from None
    description = f'استحقاق رواتب {run.month}/{run.year} (المسير #{run.id})'
    accrual = JournalEntry(date=now, description=description, entry_type='استحقاق رواتب',
                           reference_type=RUN_ACCRUAL, reference_id=int(run.id),
                           reference_number=f'{run.year}-{run.month:02d}', created_by=by,
                           is_posted=True, posted_at=now, posted_by=by)
    db.session.add(accrual)
    db.session.flush()
    total = round(sum(line.net_salary for line in lines), 2)
    create_dual_journal_entry(journal_entry_id=accrual.id, account_id=expense.id, cash_debit=total,
                              description=description)
    for line, payable_id in payables:
        create_dual_journal_entry(journal_entry_id=accrual.id, account_id=payable_id,
                                  cash_credit=line.net_salary,
                                  description=f'راتب {line.employee.name} {run.month}/{run.year}')
    if not verify_dual_balance(accrual.id).get('balanced', True):
        raise PayrollRefused('لم يتوازن قيد استحقاق المسير')
    _recalculate_account_balances_for_accounts({expense.id, *(payable_id for _, payable_id in payables)})
    return accrual


def accrual_of(run):
    """Its posted accrual, standing (not reversed) -- or None."""
    accrual = JournalEntry.query.filter_by(reference_type=RUN_ACCRUAL, reference_id=int(run.id),
                                           is_deleted=False).first()
    if accrual is None:
        return None
    reversed_ = JournalEntry.query.filter_by(reference_type=RUN_REVERSAL, reference_id=int(run.id),
                                             is_deleted=False).first()
    return None if reversed_ is not None else accrual


# ── 4. cancelled whole ─────────────────────────────────────────────────────────

def cancel(run, *, by: str, now) -> None:
    """A draft's lines removed; an approved run's accrual reversed. Caller commits."""
    if run.status == 'cancelled':
        return
    lines = run.entries.all()
    if any(line.voucher_id or line.status == 'paid' for line in lines):
        raise PayrollRefused('صُرف من المسير راتب: لا يُلغى. يُلغى سند الصرف أولًا إن كان خطأ.')
    if run.status == 'draft':
        for line in lines:
            db.session.delete(line)
    else:
        accrual = accrual_of(run)
        if accrual is not None:
            from services.payroll_laws import reverse_entry
            reverse_entry(accrual, reference_type=RUN_REVERSAL, reference_id=int(run.id),
                          description=f'عكس استحقاق رواتب {run.month}/{run.year} (إلغاء المسير #{run.id})',
                          by=by, now=now)
        for line in lines:
            line.status = 'cancelled'
    run.status = 'cancelled'
    db.session.flush()


# ── 5. paid in a batch ─────────────────────────────────────────────────────────

def pay_run(run, data: dict, *, by: str, now) -> None:
    """Each unpaid line by its voucher, from the account of how its employee is
    paid (or the one named for the line) -- all or none. Caller commits."""
    from services.payroll_payment import pay
    if run.status not in ('approved', 'paid'):
        raise PayrollRefused('يُعتمد المسير أولًا، ثم يُصرف')
    try:
        paid_date = date.fromisoformat(str(data.get('paid_date') or now.date().isoformat()))
    except ValueError:
        raise PayrollRefused('تاريخ الصرف YYYY-MM-DD') from None
    by_method = {'bank': data.get('bank_account_id'), 'cash': data.get('cash_account_id')}
    named = {int(row['payroll_id']): row for row in (data.get('lines') or [])}
    unpaid = [line for line in run.entries.order_by(Payroll.id) if not line.voucher_id]
    plan, unpayable = [], []
    for line in unpaid:
        row = named.get(line.id, {})
        account_id = row.get('payment_account_id') or by_method.get(line.employee.payment_method)
        if not account_id:
            unpayable.append(line.employee.name)
        plan.append((line, account_id, row.get('advance_deduction_amount')))
    if unpayable:
        raise PayrollRefused('لم يُحدَّد حساب الصرف لـ: ' + '، '.join(unpayable)
                             + '. حدّد طريقة صرف الموظف (تحويل أو نقد) أو حساب السطر.')
    savepoint = db.session.begin_nested()
    try:
        for line, account_id, advance in plan:
            pay(line, payment_account_id=account_id, paid_date=paid_date, advance_deduction=advance,
                by=by, now=now)
        run.status = 'paid'
        db.session.flush()
    except Exception:
        savepoint.rollback()
        raise
    savepoint.commit()


# ── the payslip ────────────────────────────────────────────────────────────────

def payslip(entry) -> dict:
    """What the employee was paid, and why: the frozen breakdown, the voucher."""
    employee = entry.employee
    breakdown = json.loads(entry.breakdown) if entry.breakdown else None
    return {'entry': entry.to_dict(include_voucher=True), 'breakdown': breakdown,
            'run': entry.run.to_dict() if entry.run else None,
            'employee': {'id': employee.id, 'name': employee.name, 'employee_code': employee.employee_code,
                         'job_title': employee.job_title, 'national_id': employee.national_id,
                         'payment_method': employee.payment_method, 'iban': employee.iban,
                         'bank_name': employee.bank_name}}
