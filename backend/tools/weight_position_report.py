"""Weight closing, as the owner means it -- a read-only report (WEIGHT-CLOSE phase 0, 16 Oct 2026).

The owner: the shop measures itself in gold; cash is a passing state. A sale
turns grams into cash; closing turns that cash back into grams. Sold 10 g for
6,000 (the market at 500): expected +2 g; if the price rises to 750 before the
6,000 buys gold again, it buys 8 g -- a 2 g loss. So an open order is a debt
in RIYALS waiting to become gold, and its weight result moves with the price
until it is closed.

The owner's decisions (16 Oct 2026):
  - a sale opens its whole price, without VAT;
  - closing it: a scrap purchase from a customer, and any purchase or expense
    paid in cash;
  - every operating expense closes its share with no grams bought -- its
    weight effect shows; manufacturing wages (510) are such an expense.

What counts as a revenue or an expense is the one definition gram profit
reads (services/gram_profit_accounts: the accounts the owner marked): a cash
revenue opens riyals with no grams sold, a cash expense closes riyals with no
grams bought, and a weight line on them is a weight result at once. Suppliers:
their gold is owed by weight and paid by weight -- on the 15 Oct 2026 copy no
supplier's gold was paid in cash -- so they close nothing here.

This report derives the position from the posted books alone -- invoices and
the operating-expense lines -- by replaying a first-in-first-out queue. It
writes nothing. Run it on a restored copy:

    DATABASE_URL=postgresql:///<copy> python tools/weight_position_report.py \\
        --since 2026-01-01 --out report.md
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SALE, SALE_RETURN, CUSTOMER_BUY, CUSTOMER_BUY_RETURN = 'بيع', 'مرتجع بيع', 'شراء من عميل', 'مرتجع شراء'
PURCHASE, SUPPLIER_RETURN = 'شراء', 'مرتجع شراء (مورد)'

KIND_LABEL = {
    'customer': 'شراء كسر من العملاء',
    'office': 'تسوية مكاتب التسكير',
    'expense': 'المصروفات (الموسومة لربح الجرام)',
}


class Lot:
    """One opening: what a sale (or a return of bought gold) turned into cash."""
    __slots__ = ('ref', 'when', 'cash', 'grams', 'price', 'cash_open', 'grams_open')

    def __init__(self, ref, when, cash, grams, price):
        self.ref, self.when, self.cash, self.grams, self.price = ref, when, cash, grams, price
        self.cash_open, self.grams_open = cash, grams


def _month(when) -> str:
    return when.strftime('%Y-%m')


def _day(when):
    return when.date() if isinstance(when, dt.datetime) else when


def collect(since: dt.date, until: dt.date):
    from accounting.balances import counted_line_filters
    from models import Account, Invoice, JournalEntry, JournalEntryLine, db
    from pricing.karat_service import get_main_karat
    from services.gram_profit_accounts import gram_profit_accounts
    from services.sales_vat import posted_sales_vat
    from routes import _invoice_weight_in_main_karat
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES

    start = dt.datetime.combine(since, dt.time.min)
    end = dt.datetime.combine(until, dt.time.max)
    invoices = (Invoice.query
                .filter(Invoice.is_posted.is_(True), Invoice.date >= start, Invoice.date <= end)
                .filter(db.func.coalesce(Invoice.status, '').notin_(list(RETRACTED_INVOICE_STATUSES)))
                .order_by(Invoice.date, Invoice.id).all())

    # A sale's VAT is what its posted entry carries (the owner, 11 Oct 2026),
    # not the invoice's total_tax field -- gram profit reads the same.
    sales_vat = posted_sales_vat([inv.id for inv in invoices if inv.invoice_type in (SALE, SALE_RETURN)])
    openings, closings, returns, skipped = [], [], [], collections.Counter()
    for inv in invoices:
        kind = (inv.invoice_type or '').strip()
        if kind in (SALE, SALE_RETURN):
            cash = float(inv.total or 0) - sales_vat.get(inv.id, 0.0)
        else:
            cash = float(inv.total or 0) - float(inv.total_tax or 0)
        grams = _invoice_weight_in_main_karat(inv)
        if kind == SALE:
            openings.append(Lot(f'بيع #{inv.invoice_type_id} ({inv.id})', inv.date, cash, grams,
                                float(inv.profit_weight_price_per_gram or 0) or None))
        elif kind == CUSTOMER_BUY_RETURN:
            # Gold given back for cash: gold out, cash in -- an opening, like a sale.
            openings.append(Lot(f'{kind} ({inv.id})', inv.date, cash, grams, None))
        elif kind == SALE_RETURN:
            returns.append((inv.date, inv.original_invoice_id, cash, grams, inv.id))
        elif kind == CUSTOMER_BUY:
            closings.append((inv.date, 'customer', cash, grams, inv.id))
        elif kind == PURCHASE and inv.office_id is not None:
            closings.append((inv.date, 'office', cash, grams, inv.id))
        elif kind in (PURCHASE, SUPPLIER_RETURN):
            skipped['supplier purchase or return (gold for gold)'] += 1
        else:
            skipped[kind or '?'] += 1

    # The revenues and expenses gram profit counts, when they are entered.
    revenue_ids, expense_ids = gram_profit_accounts()
    main_karat = float(get_main_karat() or 21)
    weights = {a.id: bool(a.tracks_weight) for a in
               Account.query.filter(Account.id.in_(revenue_ids | expense_ids or {-1}))}
    lines = (db.session.query(JournalEntry.date, JournalEntryLine)
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters())
             .filter(JournalEntryLine.account_id.in_(revenue_ids | expense_ids or {-1}),
                     JournalEntry.date >= start, JournalEntry.date <= end).all())
    per_day = collections.defaultdict(collections.Counter)
    direct = []
    for when, ln in lines:
        credit_less_debit = float(ln.cash_credit or 0) - float(ln.cash_debit or 0)
        if ln.account_id in revenue_ids:
            per_day[_day(when)]['revenue'] += credit_less_debit      # riyals in, no grams sold
        else:
            per_day[_day(when)]['expense'] -= credit_less_debit      # riyals out, no grams bought
        # A weight line is a weight result at once: credit adds (a revenue, an
        # expense reversed), debit takes -- on either side.
        karats = (18, 21, 22, 24) if weights.get(ln.account_id) else (21,)
        grams = sum((float(getattr(ln, f'credit_{k}k', 0) or 0) - float(getattr(ln, f'debit_{k}k', 0) or 0))
                    * k / main_karat for k in karats)
        if abs(grams) > 1e-6:
            direct.append((when, grams))
    for day, c in per_day.items():
        when = dt.datetime.combine(day, dt.time(23, 59))
        if c['revenue'] > 0.005:
            openings.append(Lot(f'إيرادات {day}', when, c['revenue'], 0.0, None))
        if c['expense'] > 0.005:
            closings.append((when, 'expense', c['expense'], 0.0, None))
    return openings, closings, returns, skipped, direct


def replay(openings, closings, returns, direct):
    """First in, first out: each closing consumes the oldest open riyals.
    At each month's end the open riyals and grams are kept, to be valued."""
    by_ref_id = {}
    for lot in openings:
        if lot.ref.startswith('بيع'):
            by_ref_id[int(lot.ref.rsplit('(', 1)[1].rstrip(')'))] = lot

    events = ([(lot.when, 0, 'open', lot) for lot in openings]
              + [(r[0], 1, 'return', r) for r in returns]
              + [(c[0], 2, 'close', c) for c in closings]
              + [(d[0], 3, 'direct', d) for d in direct])
    events.sort(key=lambda e: (e[0], e[1]))

    queue = collections.deque()
    month = collections.defaultdict(lambda: collections.Counter())
    by_kind = collections.defaultdict(collections.Counter)
    anomalies = collections.Counter()
    month_end = {}
    current = None

    def snapshot(m):
        month_end[m] = (sum(l.cash_open for l in queue), sum(l.grams_open for l in queue))

    for when, _, what, payload in events:
        m = _month(when)
        if current is not None and m != current:
            snapshot(current)
        current = m
        if what == 'direct':
            month[m]['direct_wpl'] += payload[1]
            by_kind['direct']['realized_wpl'] += payload[1]
            continue
        if what == 'open':
            queue.append(payload)
            month[m]['opened_cash'] += payload.cash
            month[m]['opened_grams'] += payload.grams
            if payload.price:
                month[m]['expected_wpl'] += payload.cash / payload.price - payload.grams
            continue
        if what == 'return':
            _, original, cash, grams, _id = payload
            lot = by_ref_id.get(original)
            if lot is None or lot.cash_open < cash - 0.01:
                anomalies['return of a sale already closed or outside the period'] += 1
                if lot is not None:
                    lot.cash_open = max(lot.cash_open - cash, 0.0)
                    lot.grams_open = max(lot.grams_open - grams, 0.0)
                continue
            lot.cash_open -= cash
            lot.grams_open -= grams
            month[m]['returned_cash'] += cash
            continue
        _, kind, cash, grams, _id = payload
        remaining = cash
        while remaining > 0.005 and queue:
            lot = queue[0]
            if lot.cash_open <= 0.005:
                queue.popleft()
                continue
            take = min(lot.cash_open, remaining)
            grams_out = lot.grams_open * take / lot.cash_open if lot.cash_open else 0.0
            grams_in = grams * take / cash if cash else 0.0
            lot.cash_open -= take
            lot.grams_open -= grams_out
            remaining -= take
            for bucket in (month[m], by_kind[kind]):
                bucket['closed_cash'] += take
                bucket['grams_in'] += grams_in
                bucket['grams_out'] += grams_out
                bucket['realized_wpl'] += grams_in - grams_out
            month[m][f'closed_{kind}'] += take
        if remaining > 0.005:
            # More bought than the period's sales left open: cash on hand
            # from before the period turned into gold.
            by_kind[kind]['unmatched_cash'] += remaining
            by_kind[kind]['unmatched_grams'] += grams * remaining / cash if cash else 0.0
            month[m]['unmatched_cash'] += remaining
    if current is not None:
        snapshot(current)
    open_lots = [lot for lot in queue if lot.cash_open > 0.005]
    return month, by_kind, open_lots, anomalies, month_end


def purchase_price(until: dt.date, days: int = 7):
    """What the shop paid per gram (main karat) for customers' gold in the last
    *days* days -- the price the open riyals will buy back at (the owner, 16 Oct
    2026). None bought then: the last purchase's. From the invoices alone."""
    from models import Invoice
    from routes import _invoice_weight_in_main_karat
    end = dt.datetime.combine(until, dt.time.max)
    query = Invoice.query.filter(Invoice.invoice_type == CUSTOMER_BUY, Invoice.is_posted.is_(True),
                                 Invoice.date <= end)
    rows = query.filter(Invoice.date >= end - dt.timedelta(days=days)).all()
    source = f'متوسط شراء الكسر في آخر {days} أيام'
    if not rows:
        last = query.order_by(Invoice.date.desc()).first()
        rows, source = ([last], f'آخر شراء ({last.date:%Y-%m-%d})') if last else ([], 'لا شراء')
    cash = sum(float(r.total or 0) for r in rows)
    grams = sum(_invoice_weight_in_main_karat(r) for r in rows)
    return (cash / grams if grams else 0.0), source


def price_at(day: dt.date, main_karat: float) -> float:
    """The main karat's price per gram on *day*: the last gold price saved by then."""
    from models import GoldPrice
    from pricing.gold_price_service import SAR_USD_PEG, TROY_OZ_TO_GRAMS
    row = (GoldPrice.query.filter(GoldPrice.date <= dt.datetime.combine(day, dt.time.max))
           .order_by(GoldPrice.date.desc()).first())
    if row is None or not row.price:
        return 0.0
    return float(row.price) / TROY_OZ_TO_GRAMS * SAR_USD_PEG * main_karat / 24.0


def current_system_figures():
    from models import Invoice, WeightClosingExecution, WeightClosingOrder, db
    rows = (db.session.query(Invoice.invoice_type, WeightClosingOrder.status,
                             db.func.count(), db.func.sum(WeightClosingOrder.remaining_weight_main_karat))
            .join(Invoice, Invoice.id == WeightClosingOrder.invoice_id)
            .group_by(Invoice.invoice_type, WeightClosingOrder.status).all())
    ex = (db.session.query(WeightClosingExecution.execution_type, db.func.count(),
                           db.func.sum(WeightClosingExecution.weight_main_karat),
                           db.func.avg(WeightClosingExecution.price_per_gram))
          .group_by(WeightClosingExecution.execution_type).all())
    prices = (db.session.query(db.func.avg(WeightClosingOrder.close_price_per_gram),
                               db.func.avg(Invoice.profit_weight_price_per_gram))
              .join(Invoice, Invoice.id == WeightClosingOrder.invoice_id)
              .filter(Invoice.invoice_type == SALE).one())
    return rows, ex, prices


def render(args, openings, closings, skipped, month, by_kind, open_lots, anomalies, live_main, month_end, main_karat):
    f = lambda x, d=2: f'{x:,.{d}f}'  # noqa: E731
    out = ['# التسكير الوزني بمنطق المالك — المرحلة 0 (قراءة فقط)', '',
           f'- الفترة: {args.since} → {args.until} · العيار الرئيسي {main_karat:g} · '
           f'سعر اليوم: {f(live_main)} ريال/غ', '']

    opened_cash = sum(l.cash for l in openings)
    opened_grams = sum(l.grams for l in openings)
    expected = sum((l.cash / l.price - l.grams) for l in openings if l.price)
    realized = sum(k['realized_wpl'] for name, k in by_kind.items() if name != 'direct')
    direct = by_kind.get('direct', {}).get('realized_wpl', 0.0)
    cash_open = sum(l.cash_open for l in open_lots)
    grams_open = sum(l.grams_open for l in open_lots)
    buy_price, buy_source = purchase_price(args.until)
    unrealized = (cash_open / buy_price - grams_open) if buy_price else 0.0
    unrealized_market = (cash_open / live_main - grams_open) if live_main else 0.0
    out += ['## الخلاصة', '',
            '| | |', '|---|---|',
            f'| المصادر (مبيعات وإيرادات) | {len(openings):,} · {f(opened_cash, 0)} ريال · {f(opened_grams, 1)} غ مُباعة |',
            f'| الربح الوزني المتوقع وقت البيع | {f(expected, 1)} غ |',
            f'| المحقَّق بالتسكير | {f(realized, 1)} غ |',
            f'| أثر وزني مباشر (حسابات وزنية موسومة) | {f(direct, 1)} غ |',
            f'| المفتوح الآن | {len(open_lots):,} · {f(cash_open, 0)} ريال تنتظر · {f(grams_open, 1)} غ مُباعة |',
            f'| غير المحقَّق بسعر شرائك ({f(buy_price)}، {buy_source}) | {f(unrealized, 1)} غ |',
            f'| — وبسعر السوق ({f(live_main)}) للمقارنة | {f(unrealized_market, 1)} غ |',
            f'| **الربح الوزني الكلي** | **{f(realized + direct + unrealized, 1)} غ** |', '']

    out += ['## من سكّر، وبأي نتيجة', '',
            '| | ريال سُكِّر | غ مشتراة | نصيبه من المُباع (غ) | الربح الوزني (غ) | ريال بلا بيع مفتوح يقابله |',
            '|---|---|---|---|---|---|']
    for kind in ('customer', 'office', 'expense'):
        k = by_kind.get(kind)
        if not k:
            continue
        out.append(f'| {KIND_LABEL[kind]} | {f(k["closed_cash"], 0)} | {f(k["grams_in"], 1)} | '
                   f'{f(k["grams_out"], 1)} | {f(k["realized_wpl"], 1)} | {f(k["unmatched_cash"], 0)} |')
    out.append('')

    out += ['## شهريًّا', '',
            '| الشهر | فُتح (ريال) | فُتح (غ) | المتوقع (غ) | سُكِّر (ريال) | منه مصروفات | مشترى (غ) | '
            'نصيب المُباع (غ) | المحقَّق (غ) |',
            '|---|---|---|---|---|---|---|---|---|']
    for m in sorted(month):
        r = month[m]
        out.append(f'| {m} | {f(r["opened_cash"], 0)} | {f(r["opened_grams"], 1)} | {f(r["expected_wpl"], 1)} | '
                   f'{f(r["closed_cash"], 0)} | {f(r["closed_expense"], 0)} | {f(r["grams_in"], 1)} | '
                   f'{f(r["grams_out"], 1)} | {f(r["realized_wpl"], 1)} |')
    out.append('')

    out += ['## العرض الثاني: الأداء لكل شهر (المحقَّق + المباشر + تغيّر غير المحقَّق)', '',
            '| الشهر | سعر نهاية الشهر | المفتوح (ريال) | غير المحقَّق (غ) | المحقَّق (غ) | المباشر (غ) | '
            'تغيّر غير المحقَّق (غ) | **أداء الشهر (غ)** |',
            '|---|---|---|---|---|---|---|---|']
    previous_u = 0.0
    for m in sorted(month):
        year, mon = map(int, m.split('-'))
        last = (dt.date(year + mon // 12, mon % 12 + 1, 1) - dt.timedelta(days=1))
        price = live_main if last >= args.until else price_at(last, main_karat)
        cash_m, grams_m = month_end.get(m, (0.0, 0.0))
        u = (cash_m / price - grams_m) if price else 0.0
        r = month[m]
        perf = r['realized_wpl'] + r['direct_wpl'] + (u - previous_u)
        out.append(f'| {m} | {f(price)} | {f(cash_m, 0)} | {f(u, 1)} | {f(r["realized_wpl"], 1)} | '
                   f'{f(r["direct_wpl"], 1)} | {f(u - previous_u, 1)} | **{f(perf, 1)}** |')
        previous_u = u
    out.append('')

    if open_lots:
        ages = collections.Counter()
        today = dt.datetime.combine(args.until, dt.time.max)
        for lot in open_lots:
            days = (today - lot.when).days
            ages['≤ 7 أيام' if days <= 7 else '≤ 30 يومًا' if days <= 30 else '≤ 90 يومًا' if days <= 90
                 else 'أقدم'] += lot.cash_open
        out += ['## عمر المفتوح (ريال)', '', '| | |', '|---|---|']
        out += [f'| {k} | {f(v, 0)} |' for k, v in ages.items()]
        out += ['', f'أقدم مفتوح: {min(l.when for l in open_lots):%Y-%m-%d}', '']

    rows, ex, prices = current_system_figures()
    out += ['## النظام اليوم، للمقارنة', '', '| الفاتورة | الحالة | أوامر | الباقي (غ) |', '|---|---|---|---|']
    out += [f'| {t} | {s} | {c:,} | {f(float(w or 0), 1)} |' for t, s, c, w in rows]
    out += ['', '| التنفيذ | عدد | غ | متوسط السعر |', '|---|---|---|---|']
    out += [f'| {t} | {c:,} | {f(float(w or 0), 1)} | {f(float(p or 0))} |' for t, c, w, p in ex]
    out += ['', f'متوسط سعر الإغلاق في الأوامر {f(float(prices[0] or 0))}، ومتوسط سعر السوق المحفوظ '
                f'على فواتير البيع {f(float(prices[1] or 0))} (عيار رئيسي).', '']

    notes = [f'{k}: {v}' for k, v in skipped.items()] + [f'{k}: {v}' for k, v in anomalies.items()]
    if notes:
        out += ['## ما لم يدخل الحساب', ''] + [f'- {n}' for n in notes] + ['']
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--since', type=dt.date.fromisoformat, default=dt.date(2026, 1, 1))
    ap.add_argument('--until', type=dt.date.fromisoformat, default=dt.date.today())
    ap.add_argument('--out', default='-')
    args = ap.parse_args()

    from app import app
    from models import db
    from pricing.gold_price_service import get_current_gold_price
    with app.app_context():
        try:
            from pricing.karat_service import get_main_karat
            main_karat = float(get_main_karat() or 21)
            openings, closings, returns, skipped, direct = collect(args.since, args.until)
            month, by_kind, open_lots, anomalies, month_end = replay(openings, closings, returns, direct)
            live_main = float(get_current_gold_price().get('price_per_gram_main_karat') or 0)
            text = render(args, openings, closings, skipped, month, by_kind, open_lots, anomalies, live_main,
                          month_end, main_karat)
        finally:
            db.session.rollback()       # read only: nothing it touched is kept
    if args.out == '-':
        print(text)
    else:
        with open(args.out, 'w', encoding='utf-8') as fh:
            fh.write(text)
        print(f'report: {args.out}')


if __name__ == '__main__':
    main()
