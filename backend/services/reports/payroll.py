"""The payroll: the period's salaries by month, employee or line, against the salary expense (REPORTS ت6-2ب, ADR-083).

From the payroll's lines, approved or paid, of the months the period touches:
what each earned, its additions, its bonuses (paid from the bonus payables,
not the expense), its absence (not earned) and its other deductions (advances,
penalties, contributions), its net -- and its salary expense: the run's own
reckoning (services/payroll_run.line_parts, what the run's accrual debits),
or, for a salary accrued alone before the runs, its net (what that accrual
debited). On the 2 Nov copy October's run is 67,385 earned and bonused while
its expense is 41,667: its bonuses (22,385) and absence (3,333) are not the
expense.

Checked against the books: the salary expense's net debit over the same
months -- an accrual is dated its month's last day since ت6-2أ (and its tool
puts the earlier ones there). What does not agree is said, and by how much:
February 2026 holds three months' salaries in one entry, from before the
accruals; a voucher posted on the salary account is not a payroll's.
"""
from __future__ import annotations

import calendar
import collections
import datetime as dt
import json

from services.reports.contract import Chart, Check, Column, Report

BY = ('month', 'employee', 'line')
COUNTED = ('approved', 'paid')
FIGURES = ('earned', 'additions', 'bonuses', 'absence', 'deductions', 'net', 'expense')


def _months(start: dt.date, end: dt.date) -> list[tuple[int, int]]:
    """Every (year, month) the period touches."""
    out, y, m = [], start.year, start.month
    while (y, m) <= (end.year, end.month):
        out.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def parts(line) -> dict:
    """A line's figures, the books' way."""
    if line.payroll_run_id and line.breakdown:
        from services.payroll_run import ABSENCE, kind_of, line_parts
        breakdown = json.loads(line.breakdown)
        own = line_parts(line)
        absence = sum(float(r['amount']) for r in breakdown.get('deductions') or [] if kind_of(r) == ABSENCE)
        return {'earned': sum(breakdown['earned'].values()),
                'additions': sum(float(r['amount']) for r in breakdown.get('additions') or []),
                'bonuses': own['bonuses'], 'absence': absence,
                'deductions': own['advance'] + own['penalties'] + own['contributions_payable']
                - own['contributions_expense'],
                'net': own['net'], 'expense': own['salary_expense']}
    # a salary accrued alone, before the runs: its accrual debited its net
    return {'earned': float(line.basic_salary or 0.0) + float(line.allowances or 0.0), 'additions': 0.0,
            'bonuses': 0.0, 'absence': 0.0, 'deductions': float(line.deductions or 0.0),
            'net': float(line.net_salary or 0.0), 'expense': float(line.net_salary or 0.0)}


def _books(months) -> float:
    """The salary expense's net debit from the first month's first day to the last's end."""
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from accounting.chart_tree import subtree_ids
    from models import JournalEntry, JournalEntryLine, db
    from services.employee_accounts import SALARY_EXPENSE, parent_account
    (y0, m0), (y1, m1) = months[0], months[-1]
    lo = dt.datetime(y0, m0, 1)
    hi = dt.datetime(y1, m1, calendar.monthrange(y1, m1)[1]) + dt.timedelta(days=1)
    return float(db.session.query(func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
                 .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                 .filter(*counted_line_filters(), JournalEntry.date >= lo, JournalEntry.date < hi,
                         JournalEntryLine.account_id.in_(subtree_ids(parent_account(SALARY_EXPENSE).id))).scalar()
                 or 0.0)


def payroll_report(*, start: dt.date, end: dt.date, by: str = 'month', now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from sqlalchemy import and_, or_

    from models import Employee, Payroll
    if by not in BY:
        raise ValueError(f'by is {"|".join(BY)}, not {by!r}')
    months = _months(start, end)
    lines = (Payroll.query.filter(Payroll.status.in_(COUNTED))
             .filter(or_(*(and_(Payroll.year == y, Payroll.month == m) for y, m in months)))
             .order_by(Payroll.year, Payroll.month, Payroll.employee_id).all())
    names = {e.id: e.name for e in Employee.query.filter(Employee.id.in_({l.employee_id for l in lines} or {-1}))}

    groups = collections.OrderedDict()
    for line in lines:
        month = f'{line.year}-{line.month:02d}'
        name = names.get(line.employee_id, str(line.employee_id))
        key, label, drill = {
            'month': (month, month, None),
            'employee': (line.employee_id, name, {'kind': 'employee', 'id': line.employee_id}),
            'line': (line.id, f'{name} — {month}', {'kind': 'employee', 'id': line.employee_id}),
        }[by]
        g = groups.setdefault(key, {'group': label, 'drill': drill, 'count': 0, 'paid': None,
                                    **{f: 0.0 for f in FIGURES}})
        g['count'] += 1
        for f, v in parts(line).items():
            g[f] += v
        if by == 'line' and line.paid_date:
            g['paid'] = line.paid_date.isoformat()
    order = groups.values() if by != 'employee' else sorted(groups.values(), key=lambda g: -g['net'])
    rows = [{'group': g['group'], 'drill': g['drill'], 'count': g['count'],
             **{f: round(g[f], 2) or None for f in FIGURES if f not in ('net', 'expense')},
             'net': round(g['net'], 2), 'expense': round(g['expense'], 2),
             **({'paid': g['paid']} if by == 'line' else {})} for g in order]
    totals = {f: round(sum(g[f] for g in groups.values()), 2) for f in FIGURES}
    totals['count'] = len(lines)

    books = _books(months)
    gap = round(totals['expense'] - books, 2)
    accounts = 'مصروف الرواتب في الدفاتر'
    says = (f'مطابق ل{accounts}' if abs(gap) < 0.01 else
            f'لا يطابق {accounts}: المسير {"أكثر" if gap > 0 else "أقل"} بـ {abs(gap):,.2f} (الدفاتر {books:,.2f})')
    label = {'month': 'الشهر', 'employee': 'الموظف', 'line': 'الموظف — الشهر'}[by]
    columns = [Column('group', label), Column('count', 'الرواتب', 'count'),
               Column('earned', 'المستحق', 'money'), Column('additions', 'الإضافات', 'money'),
               Column('bonuses', 'المكافآت', 'money'), Column('absence', 'الغياب', 'money'),
               Column('deductions', 'الخصومات', 'money'), Column('net', 'الصافي', 'money'),
               Column('expense', 'مصروف الرواتب', 'money')]
    if by == 'line':
        columns.append(Column('paid', 'صُرف', 'date'))
    return Report(id='payroll', title='تقرير الرواتب', basis='documents', columns=columns, rows=rows,
                  totals=totals, checks=[Check('books_agree', says, abs(gap) < 0.01)], start=start, end=end,
                  read_at=now, chart=Chart('group', 'expense') if by == 'month' else None)
