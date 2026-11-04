"""The suppliers' aging: what the shop owes each on a day, by how old it is (REPORTS ت3-2ب, ADR-083).

From the running account's reading (services/supplier_running_account.py):
each open item in its age's bucket -- 0-30, 31-60, 61-90, over 90 days, the
customers' aging's -- its age the day less its own; in riyals or in grams
(the main karat), each on its own; what is paid ahead apart, negative; an
empty bucket said empty. Each supplier's total is its ledger balance on that
day, read again from its lines and said as a check. A day counts whole; what
comes after it is not read.
"""
from __future__ import annotations

import datetime as dt

from services.reports.contract import Check, Column, Report

DIMENSIONS = ('cash', 'gold')
BUCKETS = (('days_0_30', 'حالي (0-30)', 30), ('days_31_60', '31-60 يومًا', 60),
           ('days_61_90', '61-90 يومًا', 90), ('over_90', 'أكثر من 90 يومًا', None))
EPS = {'cash': 0.005, 'gold': 0.0005}


def _bucket(age: int) -> str:
    return next(key for key, _, most in BUCKETS if most is None or age <= most)


def _ledger(lines, dimension) -> float:
    """What the shop owes on these lines, the dimension's way."""
    from pricing.karat_service import convert_to_main_karat
    if dimension == 'cash':
        return -sum(line['cash'] for line in lines)
    return -sum(convert_to_main_karat(line[f'{k}k'], k) for line in lines for k in (18, 21, 22, 24))


def supplier_aging(*, as_of: dt.date, dimension: str, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015). *dimension*: cash | gold."""
    from models import Supplier
    from services.party_live_balances import supplier_ledger_lines
    from services.supplier_running_account import running_account
    if dimension not in DIMENSIONS:
        raise ValueError(f'dimension is {"|".join(DIMENSIONS)}, not {dimension!r}')
    eps, before = EPS[dimension], dt.datetime.combine(as_of + dt.timedelta(days=1), dt.time.min)
    digits = 3 if dimension == 'gold' else 2
    rows, totals, agrees = [], {key: 0.0 for key, _, _ in BUCKETS} | {'prepaid': 0.0, 'total': 0.0}, True
    for supplier in Supplier.query.order_by(Supplier.name).all():
        reading = running_account(supplier, as_of)[dimension]
        if abs(reading['balance']) < eps and reading['prepaid'] < eps:
            continue
        row = {key: 0.0 for key, _, _ in BUCKETS}
        for item in reading['items']:
            if item['remaining'] <= 0:
                continue
            day = item['date'].date() if isinstance(item['date'], dt.datetime) else item['date']
            row[_bucket((as_of - day).days)] += item['remaining']
        row |= {'prepaid': -reading['prepaid'] or 0.0, 'total': reading['balance']}
        agrees &= abs(_ledger(supplier_ledger_lines(supplier, before), dimension) - reading['balance']) < eps
        for key in totals:
            totals[key] += row[key]
        rows.append({'name': supplier.name, 'code': supplier.supplier_code,
                     # an empty bucket is said empty, so the owed stands out
                     **{k: (round(v, digits) or None) if k != 'total' else round(v, digits) or 0.0
                        for k, v in row.items()},
                     'drill': {'kind': 'supplier', 'id': supplier.id}})
    rows.sort(key=lambda r: -r['total'])
    kind = 'grams' if dimension == 'gold' else 'money'
    columns = [Column('code', 'الكود'), Column('name', 'المورد'),
               *(Column(key, label, kind) for key, label, _ in BUCKETS),
               Column('prepaid', 'مدفوع مقدّمًا', kind, signed=True), Column('total', 'الرصيد', kind, signed=True)]
    checks = [Check('agrees_with_ledger', 'رصيد كل مورد = رصيده في الدفتر', agrees)]
    return Report(id='supplier_aging', title='أعمار ديون الموردين', basis='posted_entries', columns=columns,
                  rows=rows, totals={k: round(v, digits) for k, v in totals.items()}, checks=checks,
                  end=as_of, read_at=now)
