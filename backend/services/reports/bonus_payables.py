"""The bonuses owed on a day: the approved documents beside what the books owe (REPORTS ت6-3, ADR-083).

The books are right (BONUS-BOOKS-1; the owner, 14 Oct 2026): a voucher, its
reversal or a manual entry on an employee's bonus account changes what he is
owed without passing through the bonus -- no voucher is attributed to a bonus
by guess. So each employee says, on a day: his bonuses approved and neither
paid, reversed nor rejected by then (their approval, payment, reversal and
rejection times), their count and sum; what the books owe on his bonus
account (services/bonus_accounts.employee_bonus_account), credit less debit
over the counted lines to the day's end; and the difference -- a finding, the
books being the truth. What the bonus payables' parent holds beside the
employees' accounts is said apart. The check: the documents agree with the
books, or by how much they do not. A day counts whole.
"""
from __future__ import annotations

import datetime as dt

from services.reports.contract import Check, Column, Report

EPS = 0.005


def _approved(before: dt.datetime) -> dict:
    """{employee id: (count, sum)} of the bonuses approved and still owed at *before*."""
    from sqlalchemy import func, or_

    from models import EmployeeBonus, db

    def open_at(column):
        return or_(column.is_(None), column >= before)

    rows = (db.session.query(EmployeeBonus.employee_id, func.count(EmployeeBonus.id), func.sum(EmployeeBonus.amount))
            .filter(EmployeeBonus.approved_at.isnot(None), EmployeeBonus.approved_at < before,
                    open_at(EmployeeBonus.paid_at), open_at(EmployeeBonus.reversed_at),
                    open_at(EmployeeBonus.rejected_at))
            .group_by(EmployeeBonus.employee_id).all())
    return {e: (int(n), float(s or 0.0)) for e, n, s in rows}


def _owed(account_ids, before: dt.datetime) -> dict:
    """{account id: credit less debit} over the counted lines before *before*."""
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    rows = (db.session.query(JournalEntryLine.account_id,
                             func.sum(JournalEntryLine.cash_credit - JournalEntryLine.cash_debit))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters(), JournalEntry.date < before,
                    JournalEntryLine.account_id.in_(account_ids or {-1}))
            .group_by(JournalEntryLine.account_id).all())
    return {a: float(v or 0.0) for a, v in rows}


def bonus_payables(*, as_of: dt.date, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from accounting.chart_tree import subtree_ids
    from models import Employee
    from services.bonus_accounts import bonus_payable_parent, employee_bonus_account
    before = dt.datetime.combine(as_of + dt.timedelta(days=1), dt.time.min)
    approved = _approved(before)
    accounts = {}
    for employee in Employee.query.order_by(Employee.name).all():
        account = employee_bonus_account(employee)
        if account is not None or employee.id in approved:
            accounts[employee.id] = (employee, account)
    parent = bonus_payable_parent()
    tree = subtree_ids(parent.id) if parent else set()
    owed = _owed(tree | {a.id for _, a in accounts.values() if a}, before)

    rows, documents_total, books_total = [], 0.0, 0.0
    for employee_id, (employee, account) in accounts.items():
        count, documents = approved.get(employee_id, (0, 0.0))
        books = owed.get(account.id, 0.0) if account else 0.0
        if not count and abs(books) < EPS:
            continue
        difference = round(documents - books, 2)
        documents_total += documents
        books_total += books
        rows.append({'name': employee.name, 'count': count, 'documents': round(documents, 2) or None,
                     'books': round(books, 2), 'difference': difference or None,
                     'style': 'finding' if abs(difference) >= 0.01 else None,
                     'drill': {'kind': 'employee', 'id': employee_id}})
    rows.sort(key=lambda r: -(r['books'] or 0.0))
    held = {a.id for _, a in accounts.values() if a}
    apart = round(sum(v for a, v in owed.items() if a in tree and a not in held), 2)
    if abs(apart) >= 0.01:
        rows.append({'name': 'على حسابات المكافآت المستحقة بلا موظف', 'books': apart, 'style': 'finding'})
        books_total += apart

    gap = round(documents_total - books_total, 2)
    says = ('المكافآت المعتمدة غير المصروفة = المستحق في الدفاتر' if abs(gap) < 0.01 else
            f'المكافآت المعتمدة غير المصروفة {"أكثر" if gap > 0 else "أقل"} من المستحق في الدفاتر بـ {abs(gap):,.2f}'
            ' — الدفاتر هي الصحيحة')
    columns = [Column('name', 'الموظف'), Column('count', 'المكافآت', 'count'),
               Column('documents', 'المعتمدة غير المصروفة', 'money'),
               Column('books', 'المستحق في الدفاتر', 'money', signed=True),
               Column('difference', 'الفرق', 'money', signed=True)]
    totals = {'count': sum(n for n, _ in approved.values()), 'documents': round(documents_total, 2),
              'books': round(books_total, 2), 'difference': gap or None}
    return Report(id='bonus_payables', title='المكافآت المستحقة', basis='posted_entries', columns=columns, rows=rows,
                  totals=totals, checks=[Check('books_agree', says, abs(gap) < 0.01)], end=as_of, read_at=now)
