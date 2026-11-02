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

Its deductions and its accrual (PAYROLL-3; the owner, 1 Nov 2026: «طبّق النظام
الأفضل والأشمل»). A line's deductions are each of a kind:
  - 'absence' (keyed): not earned -- it lessens the salary expense;
  - 'penalty' (keyed): withheld -- owed to the penalties account (art. 66: a
    penalty is not the employer's income);
  - 'contribution' (reckoned): his share of his scheme, on the wage
    registered for it (services/payroll_policy.contributions);
  - 'advance' (reckoned): the month's installment of his advance plans
    (services/payroll_advances);
  - 'advance_keyed' (keyed; the owner, 2 Nov 2026: «خصم سلفة ويتم خصمها من
    حساب سلف الموظف»): an advance not planned, taken from this salary --
    no more than what of his advance account no plan holds, and with his
    installments within the policy's cap unless he consented (art. 92).
The employer's share is the line's too, not deducted. The accrual, at the gross:
    Dr salary expense        gross + additions - absence
    Dr contributions expense the employer's share
    Cr his salary payable    the net, each
    Cr contributions payable his share + the employer's
    Cr his advance account   the installments, each
    Cr penalties payable     the penalties
tests/test_payroll_advances_and_contributions.py.

Its bonuses (PAYROLL-4; decision 4, «المكافآت: ما تنصح به أنت»). An approved
bonus not yet paid is the line's: its expense was written when it was approved
(bonus expense / his bonus payable), so the run does not spend it again -- its
accrual moves it, Dr his bonus payable, into his net; the line's voucher pays
it and marks it paid. A draft may let a bonus go; a cancelled run lets them
all go. The books are right (BONUS-BOOKS-1): an employee's bonuses come in
only when his bonus account owes them all -- on the 31 Oct copy one owed 0
against 2,512.50 approved, paid by a voucher outside the bonus screen; moved,
he is paid twice. Bonuses the books owe in part are paid at what they owe
(the owner, 1 Nov 2026: «الصحيح هو ما في الدفاتر»), shared out newest first
(2 Nov 2026: «مكافأة أكتوبر تُصرف في مسير أكتوبر» -- مبارك's September and
October were held): a bonus's own approval wrote it whole on his payable,
and what was paid outside the bonus screen was paid before the newer were
approved -- the older's. The share is each bonus's, over all his approved
ones, so one let go of keeps its share, and the others theirs. None owed
at all, they are held. tests/test_payroll_bonuses.py.

An approved unpaid leave's days come off his line's days (EMP-4,
services/employee_leave): its month is not whole, his pay by the divisor.

Its end-of-service provision (PAYROLL-5, services/payroll_eos): each line says
the month's provision -- the art. 84 entitlement at the month's end less what
his end-of-service account holds -- reckoned again at approval, and the
accrual books it: Dr end-of-service expense / Cr his end-of-service payable
(a negative one the other way). It is no part of his net.
"""
from __future__ import annotations

import calendar
import json
from datetime import date

from models import Employee, EmployeeBonus, JournalEntry, Payroll, PayrollRun, db
from services.payroll_laws import PayrollRefused, refuse_bad_period
from services.payroll_policy import contributions, policy, require, structure_on

RUN_ACCRUAL = 'payroll_run_accrual'
RUN_REVERSAL = 'payroll_run_accrual_reversal'
SNAPSHOT_SCHEMA_VERSION = 4          # 2: deduction kinds, employer share; 3: bonuses; 4: end of service

ABSENCE, PENALTY, CONTRIBUTION = 'absence', 'penalty', 'contribution'
ADVANCE_KEYED = 'advance_keyed'
KEYED_DEDUCTIONS = (ABSENCE, PENALTY, ADVANCE_KEYED)
EOS_EXPENSE = 'eos_expense'
CONTRIBUTIONS_EXPENSE = 'gosi_expense'
CONTRIBUTIONS_PAYABLE = 'gosi_payable'
PENALTIES_PAYABLE = 'payroll_penalties_payable'


def kind_of(row: dict) -> str:
    return row.get('kind') or ABSENCE          # a version-1 deduction was keyed, absence


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


def preview(month, year, *, by: str) -> dict:
    """The run as it would be drafted -- drafted by the same rules inside a
    savepoint and rolled back, so nothing is kept (HR-UX ط4: who is in and who
    is left out, and why, were known only after the draft was made). Says too
    which line would stop the batch pay: one with no way to be paid."""
    refuse_bad_period(month, year)
    month, year = int(month), int(year)
    standing = open_run(month, year)
    if standing is not None:
        raise PayrollRefused(f'لشهر {month}/{year} مسير قائم: يُفتح ويُراجَع', 'payroll_run_exists')
    savepoint = db.session.begin_nested()
    try:
        run, out = generate(month, year, by=by)
        body = run.to_dict(include_entries=True)
        body['left_out'] = out
        body['totals']['bonuses'] = round(sum(float(b.get('amount') or 0.0)
                                              for e in body['entries']
                                              for b in (e.get('breakdown') or {}).get('bonuses') or []), 2)
        body['will_not_pay'] = [{'employee_id': e['employee_id'], 'name': (e.get('employee') or {}).get('name')}
                                for e in body['entries'] if not (e.get('employee') or {}).get('payment_method')]
    finally:
        savepoint.rollback()
    body['id'] = None
    return body


def _month_after(key: int) -> int:
    year, month = divmod(key, 100)
    return (year + 1) * 100 + 1 if month == 12 else key + 1


def months_to_draft(today) -> dict:
    """The last month written -- a run not cancelled, or entries made one by one
    before the runs --, and each month after it to this one; the first without
    a run is offered (HR-UX ط4: the month was picked as a number, this one by
    default -- November offered when October was still to draft)."""
    from sqlalchemy import func
    last_run = (PayrollRun.query.filter(PayrollRun.status != 'cancelled')
                .with_entities(func.max(PayrollRun.year * 100 + PayrollRun.month)).scalar())
    last_entry = (Payroll.query.filter(Payroll.payroll_run_id.is_(None), Payroll.status.in_(('approved', 'paid')),
                                       Payroll.year >= 1000)
                  .with_entities(func.max(Payroll.year * 100 + Payroll.month)).scalar())
    now = today.year * 100 + today.month
    last = max((m for m in (last_run, last_entry) if m), default=None)
    keys = [last] if last is not None else []
    key = _month_after(last) if last is not None else now
    while key <= now:
        keys.append(key)
        key = _month_after(key)
    if len(keys) == (1 if last is not None else 0):
        keys.append(key)                                  # this month's run made: the next offered
    rows = []
    for key in keys:
        year, month = divmod(key, 100)
        run = open_run(month, year)
        state = run.status if run is not None else ('entries' if key == last_entry else 'open')
        rows.append({'month': month, 'year': year, 'state': state,
                     'run_id': run.id if run is not None else None, 'current': key == now})
    first = next((r for r in rows if r['state'] == 'open'), None)
    return {'months': rows, 'suggested': {'month': first['month'], 'year': first['year']} if first else None}


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
    # an approved unpaid leave's days are not his month's (EMP-4)
    from services.employee_leave import unpaid_days
    unpaid = unpaid_days(employee.id, period[0], period[1])
    days = max((period[1] - period[0]).days + 1 - unpaid, 0)
    whole = days == (last - first).days + 1
    share = 1 if whole else min(days, divisor) / divisor
    monthly = {'basic': structure.basic, 'housing': structure.housing, 'transport': structure.transport,
               'other_allowances': structure.other_allowances}
    earned = {key: round(value * share, 2) for key, value in monthly.items()}
    gross = round(sum(earned.values()), 2)
    deductions, employer = [], []
    for row in contributions(employee, structure, last):
        if row['employee_share']:
            deductions.append({'kind': CONTRIBUTION, 'code': row['code'], 'label': row['name'],
                               'amount': round(row['employee_share'] * share, 2)})
        if row['employer_share']:
            employer.append({'code': row['code'], 'name': row['name'],
                             'amount': round(row['employer_share'] * share, 2)})
    from services.payroll_advances import installments_for
    left = round(gross - sum(row['amount'] for row in deductions), 2)
    for row in installments_for(employee, run.month, run.year, gross):
        row['amount'] = round(min(row['amount'], left), 2)
        if row['amount'] > 0:
            deductions.append(row)
            left = round(left - row['amount'], 2)
    breakdown = {'snapshot_schema_version': SNAPSHOT_SCHEMA_VERSION, 'structure_id': structure.id,
                 'monthly': monthly, 'earned': earned, 'days': days, 'divisor': divisor, 'whole_month': whole,
                 'unpaid_leave_days': unpaid,
                 'contribution_wage': employee.contribution_wage,
                 'eos': _eos(employee, structure, last),
                 'additions': [], 'deductions': deductions, 'employer_contributions': employer,
                 'bonuses': []}
    entry = Payroll(employee_id=employee.id, month=run.month, year=run.year, payroll_run_id=run.id,
                    status='pending', created_by=by)
    _apply(entry, breakdown)
    db.session.add(entry)
    db.session.flush()
    bonuses = (EmployeeBonus.query.filter_by(employee_id=employee.id, status='approved', payroll_id=None)
               .order_by(EmployeeBonus.id).all())
    from services.bonus_accounts import owed_in_books
    approved, owed = round(sum(float(b.amount or 0.0) for b in bonuses), 2), owed_in_books(employee)
    shares = None
    if bonuses and approved > owed:
        if owed > 0:
            shares = bonus_shares(employee)
            breakdown['bonus_books_cap'] = {'approved_unpaid': approved,
                                            'owed_in_books': round(sum(shares[b.id] for b in bonuses), 2)}
        else:
            breakdown['bonuses_held'] = {'approved_unpaid': approved, 'owed_in_books': owed}
            bonuses = []
    for bonus in bonuses:
        bonus.payroll_id = entry.id
        breakdown['bonuses'].append({'bonus_id': bonus.id, 'label': _bonus_label(bonus),
                                     'amount': shares[bonus.id] if shares is not None
                                     else round(float(bonus.amount or 0.0), 2)})
    _apply(entry, breakdown)


def _eos(employee, structure, last: date) -> dict:
    from services.payroll_eos import provision
    return provision(employee, structure, last)


def _refresh_eos(lines) -> None:
    """At approval: the provision on what the account holds now."""
    from models import SalaryStructure
    for line in lines:
        breakdown = json.loads(line.breakdown)
        structure = db.session.get(SalaryStructure, breakdown['structure_id'])
        breakdown['eos'] = _eos(line.employee, structure, _month_bounds(line.month, line.year)[1])
        line.breakdown = json.dumps(breakdown, ensure_ascii=False)


def bonus_shares(employee) -> dict:
    """What the books owe of each of his approved bonuses: his bonus payable
    shared out newest first, each no more than its amount."""
    from services.bonus_accounts import owed_in_books
    left = max(owed_in_books(employee), 0.0)
    approved = EmployeeBonus.query.filter_by(employee_id=employee.id, status='approved').all()
    approved.sort(key=lambda b: (b.period_end or date.min, b.id), reverse=True)
    shares = {}
    for bonus in approved:
        share = round(min(float(bonus.amount or 0.0), left), 2)
        shares[bonus.id] = share
        left = round(left - share, 2)
    return shares


def _bonus_label(bonus) -> str:
    rule = bonus.rule
    return (rule.name if rule is not None and rule.name else None) or 'مكافأة'


def release_bonuses(entry) -> None:
    """The line's bonuses let go -- approved, unpaid, theirs to be paid again."""
    for bonus in EmployeeBonus.query.filter_by(payroll_id=entry.id):
        if bonus.status == 'approved':
            bonus.payroll_id = None


def _apply(entry, breakdown: dict) -> None:
    earned = breakdown['earned']
    entry.basic_salary = earned['basic']
    entry.allowances = round(earned['housing'] + earned['transport'] + earned['other_allowances']
                             + sum(line['amount'] for line in breakdown['additions'])
                             + sum(line['amount'] for line in breakdown.get('bonuses') or []), 2)
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
    if 'additions' in data:
        breakdown['additions'] = [_labelled(line) for line in (data.get('additions') or [])]
    if 'deductions' in data:
        # the reckoned ones stay as reckoned; the keyed ones are the reviewer's
        reckoned = [row for row in breakdown['deductions'] if kind_of(row) not in KEYED_DEDUCTIONS]
        breakdown['deductions'] = reckoned + [_labelled(line, keyed=True) for line in (data.get('deductions') or [])]
    if 'bonuses' in data:
        # the bonuses kept on the line; the others let go
        kept = {int(i) for i in (data.get('bonuses') or [])}
        breakdown['bonuses'] = [row for row in breakdown.get('bonuses') or [] if row['bonus_id'] in kept]
        for bonus in EmployeeBonus.query.filter_by(payroll_id=entry.id):
            if bonus.id not in kept:
                bonus.payroll_id = None
        if 'bonus_books_cap' in breakdown:             # each kept keeps its share; the figures said again
            approved = round(sum(float(b.amount or 0.0) for b in EmployeeBonus.query.filter(
                EmployeeBonus.id.in_(kept))), 2) if kept else 0.0
            owed = round(sum(float(row['amount']) for row in breakdown['bonuses']), 2)
            if approved > owed:
                breakdown['bonus_books_cap'] = {'approved_unpaid': approved, 'owed_in_books': owed}
            else:
                breakdown.pop('bonus_books_cap')
    if 'notes' in data:
        entry.notes = data.get('notes')
    _refuse_advance_beyond(entry, breakdown)
    _apply(entry, breakdown)
    if entry.net_salary < 0:
        raise PayrollRefused('الخصومات تزيد على المستحق: الصافي سالب')


def _labelled(line, *, keyed: bool = False) -> dict:
    label = str((line or {}).get('label') or '').strip()
    if not label:
        raise PayrollRefused('لكل إضافة أو خصم سببه')
    try:
        amount = round(float(line.get('amount')), 2)
    except (TypeError, ValueError):
        raise PayrollRefused(f'{label}: المبلغ رقم') from None
    if amount <= 0:
        raise PayrollRefused(f'{label}: المبلغ موجب')
    if not keyed:
        return {'label': label, 'amount': amount}
    kind = line.get('kind') or ABSENCE
    if kind not in KEYED_DEDUCTIONS:
        raise PayrollRefused('الخصم غياب أو جزاء أو سلفة؛ الاشتراكات وأقساط السلف المجدولة تُحسب ولا تُكتب')
    row = {'kind': kind, 'label': label, 'amount': amount}
    if kind == ADVANCE_KEYED and line.get('consent'):
        row['consent'] = True
    return row


def _refuse_advance_beyond(entry, breakdown: dict) -> None:
    """A keyed advance: from his advance account, what no plan holds, within
    the cap with his installments unless he consented (art. 92)."""
    from services.payroll_advances import account_balance, cap_of, remaining
    keyed = [row for row in breakdown['deductions'] if kind_of(row) == ADVANCE_KEYED]
    if not keyed:
        return
    employee = entry.employee
    if not employee.account_id:
        raise PayrollRefused(f'لا حساب سلف مربوط لـ {employee.name}', 'advance_account_missing')
    amount = round(sum(row['amount'] for row in keyed), 2)
    planned = sum(remaining(p) for p in employee.advance_plans.filter_by(status='active'))
    free = round(account_balance(employee) - planned, 2)
    if amount > free:
        raise PayrollRefused(f'خصم السلفة {amount:,.2f} يزيد على غير المجدول من سلفه ({max(free, 0):,.2f})',
                             'advance_beyond_balance')
    if any(row.get('consent') for row in keyed):
        return
    from models import EmployeeAdvancePlan
    without_consent = sum(row['amount'] for row in breakdown['deductions']
                          if kind_of(row) == 'advance'
                          and not getattr(db.session.get(EmployeeAdvancePlan, row.get('plan_id')), 'consent', False))
    cap = cap_of(round(sum(breakdown['earned'].values()), 2))
    if round(without_consent + amount, 2) > cap:
        raise PayrollRefused(f'خصم السلفة مع أقساطه يزيد على {cap:,.2f} (حد السياسة من أجره): '
                             'يُخصم أقل، أو يُؤشَّر «بموافقة الموظف» (المادة 92)', 'advance_over_cap')


NOT_ADDED = {
    'in_the_run': 'له سطر في المسير',
    'not_employed': 'لم يعمل في هذا الشهر',
    'has_an_entry': 'له راتب مسجّل لهذا الشهر خارج المسير',
    'no_structure': 'لا هيكل راتب ساري في آخر الشهر: أضف هيكله أولًا',
}


def add_line(run, employee, *, by: str) -> None:
    """One employee drafted into a draft by the rules it was drafted by -- his
    structure added since, or his line removed and wanted back; the lines
    already reviewed stay as they are (HR-UX ط1: cancelling the draft to add
    one lost every line's additions and deductions). Caller commits."""
    _refuse_unless_draft(run)
    first, last = _month_bounds(run.month, run.year)
    reason, period, structure = _eligibility(run, employee, first, last)
    if reason is not None:
        raise PayrollRefused(f'لا يُضاف {employee.name}: {NOT_ADDED[reason]}', 'payroll_line_not_eligible')
    _draft_line(run, employee, period, structure, first, last, int(require('day_divisor')), by)
    db.session.flush()


def remove_line(entry) -> None:
    _refuse_unless_draft(entry.run)
    release_bonuses(entry)
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
    from services.payroll_advances import refuse_overtaken
    refuse_overtaken(run)
    _refuse_bonuses_beyond_the_books(lines)
    savepoint = db.session.begin_nested()
    try:
        _refresh_eos(lines)
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


def _refuse_bonuses_beyond_the_books(lines) -> None:
    """At approval: the books still owe each line's bonuses (a voucher may have paid one since)."""
    from services.bonus_accounts import owed_in_books
    for line in lines:
        rows = json.loads(line.breakdown).get('bonuses') or []
        total = round(sum(float(row['amount']) for row in rows), 2)
        if total and total > owed_in_books(line.employee):
            raise PayrollRefused(f'مكافآت {line.employee.name} في المسير {total:,.2f} والدفاتر تقول '
                                 f'{owed_in_books(line.employee):,.2f}: أزلها من السطر أو سوِّ حسابه.')


def line_parts(line) -> dict:
    """A line's accrual: what it costs and to whom it is owed."""
    breakdown = json.loads(line.breakdown)
    by_kind = {ABSENCE: 0.0, PENALTY: 0.0, CONTRIBUTION: 0.0, 'advance': 0.0, ADVANCE_KEYED: 0.0}
    for row in breakdown.get('deductions') or []:
        by_kind[kind_of(row)] += float(row['amount'])
    earned = round(sum(breakdown['earned'].values()), 2)
    additions = round(sum(float(row['amount']) for row in breakdown.get('additions') or []), 2)
    bonuses = round(sum(float(row['amount']) for row in breakdown.get('bonuses') or []), 2)
    employer = round(sum(float(row['amount']) for row in breakdown.get('employer_contributions') or []), 2)
    return {'salary_expense': round(earned + additions - by_kind[ABSENCE], 2),
            'contributions_expense': employer,
            'net': round(line.net_salary, 2),
            'contributions_payable': round(by_kind[CONTRIBUTION] + employer, 2),
            'advance': round(by_kind['advance'] + by_kind[ADVANCE_KEYED], 2),
            'penalties': round(by_kind[PENALTY], 2),
            'bonuses': bonuses,
            'eos': round(float((breakdown.get('eos') or {}).get('provision') or 0.0), 2)}


def _write_accrual(run, lines, *, by: str, now) -> JournalEntry:
    """One entry at the gross, a credit for each deduction (the module's table)."""
    from accounting.balances import _recalculate_account_balances_for_accounts
    from accounting.mappings import AccountNotMapped, DEFAULT_MAPPING_OPERATION_TYPE, require_account
    from dual_system_helpers import create_dual_journal_entry, verify_dual_balance
    from services.employee_accounts import SALARY_EXPENSE, ensure_payable_account, parent_account
    parts = [(line, line_parts(line)) for line in lines]
    total = {key: round(sum(p[key] for _, p in parts), 2)
             for key in ('salary_expense', 'contributions_expense', 'contributions_payable', 'penalties')}
    debits, credits = [], []                       # (account id, amount, description)
    try:
        debits.append((parent_account(SALARY_EXPENSE).id, total['salary_expense'], 'مصروف الرواتب'))
        for role, key, side, label in (
                (CONTRIBUTIONS_EXPENSE, 'contributions_expense', debits, 'حصة المنشأة من الاشتراكات'),
                (CONTRIBUTIONS_PAYABLE, 'contributions_payable', credits, 'الاشتراكات المستحقة'),
                (PENALTIES_PAYABLE, 'penalties', credits, 'جزاءات العاملين')):
            if total[key] > 0:
                side.append((require_account(DEFAULT_MAPPING_OPERATION_TYPE, role), total[key], label))
        for line, part in parts:
            name = line.employee.name
            if part['eos']:
                eos_payable = int(ensure_payable_account(line.employee, 'eos_payable', by=by).id)
                expense_id = require_account(DEFAULT_MAPPING_OPERATION_TYPE, EOS_EXPENSE)
                eos_debit, eos_credit = (debits, credits) if part['eos'] > 0 else (credits, debits)
                eos_debit.append((expense_id, abs(part['eos']), f'مخصص نهاية خدمة {name}'))
                eos_credit.append((eos_payable, abs(part['eos']), f'مخصص نهاية خدمة {name}'))
            if part['bonuses'] > 0:
                from services.bonus_accounts import employee_bonus_account
                bonus_payable = employee_bonus_account(line.employee)
                if bonus_payable is None:
                    raise PayrollRefused(f'لا حساب مكافآت مربوط لـ {name}: مكافآته لا تنتقل إلى راتبه')
                debits.append((bonus_payable.id, part['bonuses'], f'مكافآت {name}'))
            credits.append((int(ensure_payable_account(line.employee, 'salary_payable', by=by).id),
                            part['net'], f'راتب {name}'))
            if part['advance'] > 0:
                if not line.employee.account_id:
                    raise PayrollRefused(f'لا حساب سلف مربوط لـ {name}')
                credits.append((int(line.employee.account_id), part['advance'], f'سلفة {name}'))
    except AccountNotMapped as missing:
        raise PayrollRefused(str(missing)) from None
    if round(sum(a for _, a, _ in debits) - sum(a for _, a, _ in credits), 2) != 0:
        raise PayrollRefused('لم يتوازن قيد استحقاق المسير')
    description = f'استحقاق رواتب {run.month}/{run.year} (المسير #{run.id})'
    accrual = JournalEntry(date=now, description=description, entry_type='استحقاق رواتب',
                           reference_type=RUN_ACCRUAL, reference_id=int(run.id),
                           reference_number=f'{run.year}-{run.month:02d}', created_by=by,
                           is_posted=True, posted_at=now, posted_by=by)
    db.session.add(accrual)
    db.session.flush()
    for account_id, amount, label in debits:
        create_dual_journal_entry(journal_entry_id=accrual.id, account_id=account_id, cash_debit=amount,
                                  description=f'{label} {run.month}/{run.year}')
    for account_id, amount, label in credits:
        if amount > 0:
            create_dual_journal_entry(journal_entry_id=accrual.id, account_id=account_id, cash_credit=amount,
                                      description=f'{label} {run.month}/{run.year}')
    if not verify_dual_balance(accrual.id).get('balanced', True):
        raise PayrollRefused('لم يتوازن قيد استحقاق المسير')
    _recalculate_account_balances_for_accounts({account_id for account_id, _, _ in debits + credits})
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
    for line in lines:
        release_bonuses(line)
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

def split_of(employee, payable: float) -> dict:
    """How his net is offered to be paid (PAY-SPLIT): by his way, whole -- or a
    fixed amount by one way (no more than the net) and the rest by the other."""
    payable = round(payable, 2)
    method, fixed = employee.split_method, employee.split_amount
    if method in ('bank', 'cash') and fixed:
        part = round(min(float(fixed), payable), 2)
        other = 'cash' if method == 'bank' else 'bank'
        return {method: part, other: round(payable - part, 2)}
    if employee.payment_method in ('bank', 'cash'):
        return {employee.payment_method: payable}
    return {}


def pay_run(run, data: dict, *, by: str, now) -> None:
    """Each unsettled line by its voucher -- by bank, by cash, or part each,
    what is not paid kept owed to him (PAY-SPLIT) -- all or none. A line's
    amounts are the dialog's, else his split (split_of). Caller commits."""
    from services.payroll_payment import pay, settled
    if run.status not in ('approved', 'paid'):
        raise PayrollRefused('يُعتمد المسير أولًا، ثم يُصرف')
    try:
        paid_date = date.fromisoformat(str(data.get('paid_date') or now.date().isoformat()))
    except ValueError:
        raise PayrollRefused('تاريخ الصرف YYYY-MM-DD') from None
    by_method = {'bank': data.get('bank_account_id'), 'cash': data.get('cash_account_id')}
    named = {int(row['payroll_id']): row for row in (data.get('lines') or [])}
    unpaid = [line for line in run.entries.order_by(Payroll.id) if not settled(line)]
    plan, unpayable = [], []
    for line in unpaid:
        row = named.get(line.id, {})
        advance = row.get('advance_deduction_amount')
        parts = None                                         # one account named for the whole line
        if not row.get('payment_account_id'):
            keyed = 'bank_amount' in row or 'cash_amount' in row
            amounts = ({'bank': row.get('bank_amount') or 0.0, 'cash': row.get('cash_amount') or 0.0} if keyed
                       else split_of(line.employee, float(line.net_salary or 0.0) - float(advance or 0.0)))
            # a way paid by is paid from its account; none at all (no way known) is not paid
            if (not keyed and not amounts) or any(float(amount or 0.0) > 0 and not by_method.get(way)
                                                   for way, amount in amounts.items()):
                unpayable.append(line.employee.name)
            parts = [(by_method.get(way), amount) for way, amount in amounts.items()]
        plan.append((line, row.get('payment_account_id'), parts, advance))
    if unpayable:
        raise PayrollRefused('لم يُحدَّد حساب الصرف لـ: ' + '، '.join(unpayable)
                             + '. حدّد طريقة صرف الموظف (تحويل أو نقد) أو حساب السطر.')
    savepoint = db.session.begin_nested()
    try:
        for line, account_id, parts, advance in plan:
            pay(line, payment_account_id=account_id, parts=parts, paid_date=paid_date,
                advance_deduction=advance, by=by, now=now)
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
