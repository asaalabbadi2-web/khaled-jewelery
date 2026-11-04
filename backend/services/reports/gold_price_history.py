"""The gold price's history by day, week or month, in Riyadh's days (REPORTS ت5-4, ADR-083).

From the recorded prices -- a basis of its own, neither entries nor
documents. Each period: its prices' count; its opening, closing, high, low
and average riyals a gram of the main karat, each price's own office gram
price by the terms it was saved with (OFFICE-PRICE-1); its average in dollars
an ounce; its change from its opening to its closing. The chart draws the
average as a line (its axis spans the prices, not from zero); a note says the whole span -- its first and last price, and the
change between. Days are Riyadh's; the stored times are UTC
(pricing/price_clock.py).
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Chart, Column, Report

BY = ('day', 'week', 'month')


def _key(moment: dt.datetime, by: str) -> str:
    if by == 'month':
        return moment.strftime('%Y-%m')
    if by == 'week':
        year, week, _ = moment.isocalendar()
        return f'{year}-W{week:02d}'
    return moment.strftime('%Y-%m-%d')


def _change(first: float, last: float) -> float | None:
    return round((last - first) / first * 100, 2) if first else None


def gold_price_history(*, start: dt.date, end: dt.date, by: str, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from models import GoldPrice
    from pricing import price_clock
    from pricing.gold_price_service import get_main_karat
    from pricing.office_price import row_gram_price
    if by not in BY:
        raise ValueError(f'by is {"|".join(BY)}, not {by!r}')
    karat = get_main_karat()
    lo, _ = price_clock.riyadh_day_bounds_utc(start)
    _, hi = price_clock.riyadh_day_bounds_utc(end)
    prices = (GoldPrice.query.filter(GoldPrice.date >= lo, GoldPrice.date < hi)
              .order_by(GoldPrice.date.asc()).all())
    periods = collections.OrderedDict()
    for row in prices:
        gram = float(row_gram_price(row, karat) or 0.0)
        periods.setdefault(_key(price_clock.to_riyadh(row.date), by), []).append((gram, float(row.price or 0.0)))

    rows = []
    for key, points in periods.items():
        grams = [g for g, _ in points]
        rows.append({'group': key, 'points': len(points), 'open': round(grams[0], 2), 'close': round(grams[-1], 2),
                     'high': round(max(grams), 2), 'low': round(min(grams), 2),
                     'average': round(sum(grams) / len(grams), 2),
                     'avg_usd': round(sum(u for _, u in points) / len(points), 2),
                     'change': _change(grams[0], grams[-1])})
    totals = {}
    if rows:
        everything = [p for points in periods.values() for p in points]
        grams = [g for g, _ in everything]
        totals = {'points': len(everything), 'high': round(max(grams), 2), 'low': round(min(grams), 2),
                  'average': round(sum(grams) / len(grams), 2), 'change': _change(grams[0], grams[-1])}
        rows.append({'group': f'من {grams[0]:,.2f} إلى {grams[-1]:,.2f} ريال لجرام عيار {karat}: '
                              f'{totals["change"]:+.2f}%', 'style': 'note'})
    label = {'day': 'اليوم', 'week': 'الأسبوع', 'month': 'الشهر'}[by]
    columns = [Column('group', label), Column('points', 'الأسعار', 'count'),
               Column('open', 'الافتتاح', 'money'), Column('close', 'الإغلاق', 'money'),
               Column('high', 'الأعلى', 'money'), Column('low', 'الأدنى', 'money'),
               Column('average', f'المتوسط (عيار {karat})', 'money'), Column('avg_usd', 'المتوسط ($/أونصة)', 'money'),
               Column('change', 'التغيّر', 'percent', signed=True)]
    return Report(id='gold_price_history', title='تاريخ أسعار الذهب', basis='prices', columns=columns, rows=rows,
                  totals=totals, start=start, end=end, read_at=now, chart=Chart('group', 'average', kind='line'))
