"""The weight position, as a report on a restored copy -- read only (ADR-048).

Everything it shows comes from services/weight_position: the queue of a
sale's riyals waiting to become gold again, derived from the posted books.
This file only lays it out.

    DATABASE_URL=postgresql:///<copy> python tools/weight_position_report.py \\
        --until 2026-10-15 --out report.md
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

KIND_LABEL = {'customer': 'شراء كسر من العملاء', 'office': 'تسوية مكاتب التسكير',
              'expense': 'المصروفات (الموسومة لربح الجرام)'}


def _f(x, d=2):
    return f'{x:,.{d}f}'


def render(until: dt.date) -> str:
    from pricing.gold_price_service import get_current_gold_price
    from pricing.karat_service import get_main_karat
    from services import weight_position as wp

    events = wp.collect_events(wp.year_start(until), dt.datetime.combine(until, dt.time.max))
    result = wp.replay(events)
    open_lots = result.open_lots
    cash_open = sum(lot.cash_open for lot in open_lots)
    grams_open = sum(lot.grams_open for lot in open_lots)
    price, source = wp.purchase_price(until)
    market = float(get_current_gold_price().get('price_per_gram_main_karat') or 0)
    realized = sum(b['result'] for k, b in result.by_kind.items() if k != 'direct')
    direct = result.by_kind.get('direct', {}).get('result', 0.0)
    unreal = wp.unrealized(cash_open, grams_open, price)
    expected = sum(lot.cash / lot.price_at_sale - lot.grams for lot in result.lots if lot.price_at_sale)

    out = ['# التسكير الوزني — المركز والأداء (قراءة فقط)', '',
           f'- من {wp.year_start(until):%Y-%m-%d} إلى {until} · العيار الرئيسي {float(get_main_karat() or 21):g}', '',
           '## الخلاصة', '', '| | |', '|---|---|',
           f'| المصادر (مبيعات وإيرادات) | {len(result.lots):,} · {_f(sum(l.cash for l in result.lots), 0)} ريال · '
           f'{_f(sum(l.grams for l in result.lots), 1)} غ مُباعة |',
           f'| الربح الوزني المتوقع وقت البيع | {_f(expected, 1)} غ |',
           f'| المحقَّق بالتسكير | {_f(realized, 1)} غ |',
           f'| أثر وزني مباشر | {_f(direct, 1)} غ |',
           f'| المفتوح الآن | {len(open_lots):,} · {_f(cash_open, 0)} ريال · {_f(grams_open, 1)} غ مُباعة |',
           f'| غير المحقَّق بسعر شرائك ({_f(price)}، {source}) | {_f(unreal, 1)} غ |',
           f'| — وبسعر السوق ({_f(market)}) للمقارنة | {_f(wp.unrealized(cash_open, grams_open, market), 1)} غ |',
           f'| **الربح الوزني الكلي** | **{_f(realized + direct + unreal, 1)} غ** |', '',
           '## من سكّر', '', '| | ريال | غ مشتراة | نصيبه من المُباع (غ) | النتيجة (غ) |', '|---|---|---|---|---|']
    for kind, label in KIND_LABEL.items():
        b = result.by_kind.get(kind)
        if b:
            out.append(f'| {label} | {_f(b["cash"], 0)} | {_f(b["grams_in"], 1)} | {_f(b["grams_out"], 1)} | '
                       f'{_f(b["result"], 1)} |')
    unmatched = collections.Counter()
    for c in result.unmatched:
        unmatched[c.kind] += c.cash
    if unmatched:
        out += ['', 'ريالات صُرفت ولا بيع مفتوح يقابلها (نقد من قبل الفترة): '
                + '، '.join(f'{KIND_LABEL.get(k, k)} {_f(v, 0)}' for k, v in unmatched.items())]

    out += ['', '## الأداء لكل شهر', '',
            '| الشهر | سعر شرائك آخر الشهر | المفتوح (ريال) | غير المحقَّق (غ) | المحقَّق (غ) | المباشر (غ) | '
            'تغيّر غير المحقَّق (غ) | **أداء الشهر (غ)** |', '|---|---|---|---|---|---|---|---|']
    previous = 0.0
    for m in sorted(result.by_month):
        year, mon = map(int, m.split('-'))
        last = min(dt.date(year + mon // 12, mon % 12 + 1, 1) - dt.timedelta(days=1), until)
        month_price, _ = wp.purchase_price(last)
        cash_m, grams_m = result.month_end.get(m, (0.0, 0.0))
        u = wp.unrealized(cash_m, grams_m, month_price)
        r = result.by_month[m]
        out.append(f'| {m} | {_f(month_price)} | {_f(cash_m, 0)} | {_f(u, 1)} | {_f(r["result"], 1)} | '
                   f'{_f(r["direct"], 1)} | {_f(u - previous, 1)} | **{_f(r["result"] + r["direct"] + u - previous, 1)}** |')
        previous = u
    notes = [f'{k}: {v}' for k, v in events.skipped.items()] + [f'{k}: {v}' for k, v in result.anomalies.items()]
    if notes:
        out += ['', '## ما لم يدخل الحساب', ''] + [f'- {n}' for n in notes]
    return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--until', type=dt.date.fromisoformat, default=dt.date.today())
    ap.add_argument('--out', default='-')
    args = ap.parse_args()
    from app import app
    from models import db
    with app.app_context():
        try:
            text = render(args.until)
        finally:
            db.session.rollback()       # read only
    if args.out == '-':
        print(text)
    else:
        with open(args.out, 'w', encoding='utf-8') as fh:
            fh.write(text)
        print(f'report: {args.out}')


if __name__ == '__main__':
    main()
