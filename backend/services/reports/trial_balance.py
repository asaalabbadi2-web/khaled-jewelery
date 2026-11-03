"""The trial balance: each account's debits and credits, in riyals and grams (REPORTS ت0-3, ADR-083).

Read from the lines accounting.balances.counted_line_filters counts (posted,
not a draft, not deleted) -- the route had its own filters, and filtered a
period on `JournalEntry.entry_date`, which the model does not have: a period
never answered. A period's end day counts whole. Gold is in the main karat
(from the settings), or karat by karat with `karat_detail`.
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Check, Column, Report

KARATS = (18, 21, 22, 24)
MONEY, GRAMS = 2, 3


def _lines(start: dt.date | None, end: dt.date | None):
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from models import Account, JournalEntry, JournalEntryLine, db
    sums = [func.sum(JournalEntryLine.cash_debit), func.sum(JournalEntryLine.cash_credit)]
    for k in KARATS:
        sums += [func.sum(getattr(JournalEntryLine, f'debit_{k}k')), func.sum(getattr(JournalEntryLine, f'credit_{k}k'))]
    query = (db.session.query(Account.id, Account.account_number, Account.name, *sums)
             .join(JournalEntryLine, JournalEntryLine.account_id == Account.id)
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters()))
    if start is not None:
        query = query.filter(JournalEntry.date >= dt.datetime.combine(start, dt.time.min))
    if end is not None:
        query = query.filter(JournalEntry.date < dt.datetime.combine(end + dt.timedelta(days=1), dt.time.min))
    return query.group_by(Account.id, Account.account_number, Account.name).order_by(Account.account_number).all()


def trial_balance(*, now: dt.datetime, start: dt.date | None = None, end: dt.date | None = None,
                  karat_detail: bool = False) -> Report:
    """*now*: the caller's clock (ADR-015), said as when it was read."""
    from pricing.karat_service import convert_to_main_karat
    rows, raw = [], collections.defaultdict(float)     # summed whole, rounded once at the end

    def add(key, value, places=None):
        raw[key] += value

    for account_id, number, name, cash_debit, cash_credit, *karats in _lines(start, end):
        cash_debit, cash_credit = float(cash_debit or 0.0), float(cash_credit or 0.0)
        by_karat = {k: (float(karats[2 * i] or 0.0), float(karats[2 * i + 1] or 0.0)) for i, k in enumerate(KARATS)}
        gold_debit = sum(convert_to_main_karat(d, k) for k, (d, _) in by_karat.items())
        gold_credit = sum(convert_to_main_karat(c, k) for k, (_, c) in by_karat.items())
        if not any((cash_debit, cash_credit, gold_debit, gold_credit)):
            continue
        row = {'account_id': account_id, 'account_number': number, 'account_name': name,
               'cash_debit': round(cash_debit, MONEY), 'cash_credit': round(cash_credit, MONEY),
               'cash_balance': round(cash_debit - cash_credit, MONEY)}
        for key, value in (('cash_debit', cash_debit), ('cash_credit', cash_credit)):
            add(key, value, MONEY)
        if karat_detail:
            for k, (d, c) in by_karat.items():
                row.update({f'debit_{k}k': round(d, GRAMS), f'credit_{k}k': round(c, GRAMS),
                            f'balance_{k}k': round(d - c, GRAMS)})
                add(f'debit_{k}k', d, GRAMS)
                add(f'credit_{k}k', c, GRAMS)
        else:
            row.update({'gold_debit': round(gold_debit, GRAMS), 'gold_credit': round(gold_credit, GRAMS),
                        'gold_balance': round(gold_debit - gold_credit, GRAMS)})
        add('gold_debit', gold_debit, GRAMS)
        add('gold_credit', gold_credit, GRAMS)
        row['drill'] = {'kind': 'account', 'id': account_id}
        rows.append(row)

    raw['cash_balance'] = raw['cash_debit'] - raw['cash_credit']
    raw['gold_balance'] = raw['gold_debit'] - raw['gold_credit']
    if karat_detail:
        for k in KARATS:
            raw[f'balance_{k}k'] = raw[f'debit_{k}k'] - raw[f'credit_{k}k']
    totals = {key: round(value, MONEY if key.startswith('cash') else GRAMS) for key, value in raw.items()}

    columns = [Column('account_number', 'رقم الحساب'), Column('account_name', 'الحساب'),
               Column('cash_debit', 'مدين نقد', 'money'), Column('cash_credit', 'دائن نقد', 'money'),
               Column('cash_balance', 'الرصيد نقد', 'money', signed=True)]
    if karat_detail:
        for k in KARATS:
            columns += [Column(f'debit_{k}k', f'مدين {k}', 'grams'), Column(f'credit_{k}k', f'دائن {k}', 'grams'),
                        Column(f'balance_{k}k', f'الرصيد {k}', 'grams', signed=True)]
    else:
        columns += [Column('gold_debit', 'مدين وزن', 'grams'), Column('gold_credit', 'دائن وزن', 'grams'),
                    Column('gold_balance', 'الرصيد وزن', 'grams', signed=True)]
    checks = [Check('cash_balanced', 'مجموع المدين = مجموع الدائن (نقد)', abs(raw['cash_balance']) < 0.005),
              Check('gold_balanced', 'مجموع المدين = مجموع الدائن (وزن)', abs(raw['gold_balance']) < 0.0005)]
    return Report(id='trial_balance', title='ميزان المراجعة', basis='posted_entries', columns=columns, rows=rows,
                  totals=totals, checks=checks, start=start, end=end, read_at=now)
