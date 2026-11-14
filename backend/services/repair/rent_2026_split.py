"""The rent of 2026 in two: as paid, and net -- the months restated in their months (ADR-090, 14 Nov 2026).

The owner's figures (services/repair/rent_2026_split.json). The 2026 tool made
the rent one period expense of 144,900 -- its VAT in it. The first half was
paid on 24 June, its VAT kept in the expense and claimed in the third
quarter's return; the second half is paid in December with its tax invoice,
the VAT on the voucher, so the books' input VAT is the accountant's statement.
So:

  - «إيجار المعرض 2026» becomes January to June, 72,450 -- what its voucher paid
    (law 7: an edit, recorded with its reason);
  - July to October, posted at 12,075 each, are restated in their months --
    each month's difference an entry of its own in that month, the months
    still open (the owner's option B, once: law 7 alone would take the whole
    difference into November);
  - «إيجار المعرض يوليو–ديسمبر 2026», 63,000 net, is made, and its months
    through *through* accrued in their months.

Refused, writing nothing (PlanRefused): the rent not as the 2026 tool left it;
a payment on it besides the first half's (the December voucher linked before
this ran); a month closed. A second run finds the second half made and writes
nothing. The dry run (the default) shows each month's rent and its weight
profit, before and after.
"""
from __future__ import annotations

import datetime as dt
import os

from models import PeriodExpense, db
from services.repair.planned_entries import PlanRefused, load

FIGURES = os.path.join(os.path.dirname(__file__), 'rent_2026_split.json')


def _day(text):
    return dt.date.fromisoformat(text)


def apply(*, through: dt.date, by: str, now: dt.datetime, dry_run: bool = True, figures: dict | None = None) -> dict:
    from services.period_expense import (
        PeriodExpenseRefused, _paid_now, accrue, create, edit, halalas, restate_in_their_months,
    )
    from services.repair.period_expense_2026 import _monthly
    figures = figures or load(FIGURES)
    rent_spec, first, second = figures['rent'], figures['first_half'], figures['second_half']
    if PeriodExpense.query.filter_by(description=second['description']).filter(
            PeriodExpense.status == 'active').count():
        return {'applied': False, 'already': True, 'message': 'الإيجار مقسوم أصلًا: لا شيء يُكتب'}
    rents = PeriodExpense.query.filter_by(description=rent_spec['description'], status='active').all()
    if len(rents) != 1:
        raise PlanRefused(f"«{rent_spec['description']}»: {len(rents)} مصروف قائم، لا واحد")
    rent = rents[0]
    as_left = (halalas(rent.amount), rent.period_start, rent.period_end)
    if as_left != (halalas(rent_spec['amount']), _day(rent_spec['start']), _day(rent_spec['end'])):
        raise PlanRefused(f'الإيجار ليس كما تركته أداة 2026: {rent.amount} من {rent.period_start} إلى {rent.period_end}')
    if _paid_now(rent) != halalas(first['paid']):
        raise PlanRefused(f"المدفوع على الإيجار {_paid_now(rent) / 100:,.2f} لا {first['paid']:,.2f}: "
                          'سند آخر مربوط به (سند ديسمبر يُربط بالنصف الثاني بعد هذه الأداة)')

    before = _monthly({rent.expense_account_id}, _day(rent_spec['start']), through)
    savepoint = db.session.begin_nested()
    try:
        edit(rent, reason=first['reason'], by=by, now=now, amount=first['amount'],
             period_start=_day(first['start']), period_end=_day(first['end']))
        restated = restate_in_their_months(rent, through=through, by=by, now=now)
        second_half = create(description=second['description'], expense_account_id=rent.expense_account_id,
                             amount=second['amount'], period_start=_day(second['start']),
                             period_end=_day(second['end']), by=by, now=now)
        run = accrue(through, by=by, now=now, dry_run=False)
    except PeriodExpenseRefused as refused:
        savepoint.rollback()
        raise PlanRefused(refused.message) from refused
    db.session.flush()
    after = _monthly({rent.expense_account_id}, _day(rent_spec['start']), through)
    plan = {
        'through': through.isoformat(), 'rent': rent.id, 'second_half': second_half.id,
        'restated': restated, 'second_half_months': [e for e in run['entries'] if e['period_expense_id'] == second_half.id],
        'other_entries': [e for e in run['entries'] if e['period_expense_id'] != second_half.id],
        'reclass': run['reclass'], 'drift': run['drift'],
        'before_after': [{'month': m, 'before': before.get(m), 'after': after.get(m)}
                         for m in sorted(set(before) | set(after))],
    }
    if dry_run:
        savepoint.rollback()
    else:
        savepoint.commit()
    plan['applied'] = not dry_run
    return plan
