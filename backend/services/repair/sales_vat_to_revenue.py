"""The sales VAT of January-May 2026 is revenue (stage-4 item 22; the owner, 11 Oct 2026).

«مبلغ ضريبة ما قبل 1/6 يجب أن يُحوَّل إلى حساب المبيعات، لأن ما كان بعد 1/5
المفروض أن يكون من بداية السنة»؛ «قيدًا لكل شهر». Sales carried 15 % VAT (24k
exempt) until the evening of 1 May 2026 and none after (SALES-VAT-1); the VAT
stayed owed on 2300 -- 533,790.72 on the 10 Oct copy -- and three April
returns gave theirs back on 2210 (2,393.48), the mapping's fallback number.

One entry at each month's end before *before*: each invoice entry's VAT, as
it posted it, goes to the revenue account that entry credited -- 41 or 400 a
sale's, by their shares when it credited both; 420 a return's. Each month's
revenue then equals its invoices' totals, and the VAT accounts close. Nothing
posted is edited. Idempotent: a month written is not written again.
"""
from __future__ import annotations

import calendar
import json
from collections import defaultdict
from datetime import date, datetime, time

from accounting.balances import counted_line_filters
from models import Account, AuditLog, JournalEntry, JournalEntryLine, db
from services.income_accounts import income_account_groups
from services.repair.entries import write_entry
from services.sales_vat import VAT_TO_REVENUE, moved_months, sales_vat_account_ids

CENT = 0.005


class NotAsMeasured(ValueError):
    pass


def _month_end(month: str) -> datetime:
    y, m = (int(p) for p in month.split('-'))
    return datetime(y, m, calendar.monthrange(y, m)[1], 23, 59, 59)


def plan(*, before: date, since: date | None = None) -> list[dict]:
    vat_ids = sales_vat_account_ids()
    if not vat_ids:
        raise NotAsMeasured('no sales VAT account mapped')
    revenue_ids = income_account_groups()['revenue']          # group 4, by the tree -- as the income statement
    number = dict(Account.query.with_entities(Account.id, Account.account_number).all())
    q = (db.session.query(JournalEntryLine, JournalEntry)
         .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(*counted_line_filters(), JournalEntry.reference_type == 'invoice',
                 JournalEntryLine.account_id.in_(vat_ids),
                 JournalEntry.date < datetime.combine(before, time.min)))
    if since is not None:
        q = q.filter(JournalEntry.date >= datetime.combine(since, time.min))
    months = defaultdict(lambda: defaultdict(float))
    for vat_line, entry in q.all():
        vat = float(vat_line.cash_credit or 0) - float(vat_line.cash_debit or 0)   # a sale's +, a return's -
        if abs(vat) < CENT:
            continue
        revenue = defaultdict(float)
        for l in entry.lines:
            if not l.is_deleted and l.account_id in revenue_ids:
                revenue[l.account_id] += float(l.cash_credit or 0) - float(l.cash_debit or 0)
        total = sum(revenue.values())
        if abs(total) < CENT:
            raise NotAsMeasured(f'{entry.entry_number}: VAT {vat:.2f} beside no revenue')
        lines = months[entry.date.strftime('%Y-%m')]
        lines[number[vat_line.account_id]] += vat                      # the VAT closes: debit a sale's
        for account_id, amount in revenue.items():                     # to its revenue, by share
            lines[number[account_id]] -= vat * amount / total
    out = []
    for m in sorted(months):
        lines = {k: round(v, 2) for k, v in months[m].items() if abs(v) > CENT}
        rest = round(sum(lines.values()), 2)
        if abs(rest) > CENT:                                           # the shares' rounding, to the largest
            largest = max((k for k in lines if lines[k] < 0), key=lambda k: -lines[k])
            lines[largest] = round(lines[largest] - rest, 2)
        out.append({'month': m, 'date': _month_end(m), 'lines': lines})
    return out


def move_sales_vat_to_revenue(*, by: str, now, before: date, since: date | None = None, dry_run: bool = True) -> dict:
    months = plan(before=before, since=since)
    done = moved_months()
    out = {'months': months, 'written': [], 'already': [m['month'] for m in months if m['month'] in done]}
    if dry_run:
        return out
    account_id = dict(Account.query.with_entities(Account.account_number, Account.id).all())
    for m in months:
        if m['month'] in done:
            continue
        description = f'تحويل ضريبة مبيعات {m["month"]} إلى المبيعات (قرار المالك 11 أكتوبر 2026)'
        entry = write_entry(
            date=m['date'], description=description, reference_type=VAT_TO_REVENUE, reference_id=None,
            reference_number=m['month'],
            lines=[{'account_id': account_id[num], 'description': description,
                    **({'cash_debit': a} if a > 0 else {'cash_credit': -a})} for num, a in sorted(m['lines'].items())],
            by=by, now=now, prefix='COR', safe_rows=False,
        )
        out['written'].append(entry.entry_number)
    if out['written']:
        db.session.add(AuditLog(user_name=by, action=VAT_TO_REVENUE, entity_type='journal_entry',
                                entity_id=JournalEntry.query.filter_by(entry_number=out['written'][0]).one().id,
                                success=True, details=json.dumps({'written': out['written'], 'before': before,
                                                                  'at': now}, ensure_ascii=False, default=str)))
        db.session.flush()
    return out
