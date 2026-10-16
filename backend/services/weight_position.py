"""The weight position: a sale's riyals waiting to become gold again, and what turning them back made (ADR-048).

The owner, 16 Oct 2026: the shop measures itself in gold; cash is a passing
state. A sale turns grams into riyals; a cash purchase of gold, or a marked
expense, turns them back -- first in, first out, by the riyal. What the
riyals bought back, less what was sold for them, is the weight profit:
realized when they are spent, unrealized while they wait (valued at the
shop's own recent purchase price, from its invoices -- no live feed).

Derived from the posted books, never stored: an edit, a return or an
unposting changes the books, and the next reading follows. Three parts:

  collect_events(start, end)  -- the sources and uses, from invoices and the
                                 marked revenue/expense lines;
  replay(events)              -- the queue (pure: no database);
  position(as_of) / performance(start, end) -- the two views.
"""
from __future__ import annotations

import collections
import datetime as dt
from dataclasses import dataclass, field

SALE, SALE_RETURN, CUSTOMER_BUY, CUSTOMER_BUY_RETURN = 'بيع', 'مرتجع بيع', 'شراء من عميل', 'مرتجع شراء'
PURCHASE, SUPPLIER_RETURN = 'شراء', 'مرتجع شراء (مورد)'

# What closes: a customer's gold bought, an office's reservation settled, a marked expense.
CUSTOMER, OFFICE, EXPENSE = 'customer', 'office', 'expense'
PURCHASE_PRICE_DAYS = 7          # the window the open riyals are valued at (the owner, 16 Oct 2026)


@dataclass
class Lot:
    """An opening: riyals in, grams out (none for a revenue)."""
    ref: str
    when: dt.datetime
    cash: float
    grams: float
    price_at_sale: float | None = None
    invoice_id: int | None = None
    cash_open: float = field(init=False)
    grams_open: float = field(init=False)

    def __post_init__(self):
        self.cash_open, self.grams_open = self.cash, self.grams


@dataclass
class Closing:
    """A use: riyals out -- into grams bought, or into an expense (no grams)."""
    when: dt.datetime
    kind: str
    cash: float
    grams: float = 0.0
    invoice_id: int | None = None


@dataclass
class Return:
    """A sale's return: its riyals and grams back off the sale it returns."""
    when: dt.datetime
    original_invoice_id: int
    cash: float
    grams: float


@dataclass
class Events:
    openings: list = field(default_factory=list)
    closings: list = field(default_factory=list)
    returns: list = field(default_factory=list)
    direct: list = field(default_factory=list)       # (when, grams): a weight line, a result at once
    skipped: collections.Counter = field(default_factory=collections.Counter)


@dataclass
class Slice:
    """A closing's take from one lot: riyals, grams bought with them, the lot's grams sold for them."""
    when: dt.datetime
    kind: str
    cash: float
    grams_in: float
    grams_out: float

    @property
    def result(self) -> float:
        return self.grams_in - self.grams_out


@dataclass
class Replay:
    lots: list
    slices: list
    direct: list                                      # (when, grams)
    by_kind: dict
    by_month: dict
    month_end: dict                                   # month -> (open riyals, open grams sold)
    unmatched: list                                   # closings with no open riyals to take
    anomalies: collections.Counter

    @property
    def open_lots(self):
        return [lot for lot in self.lots if lot.cash_open > 0.005]


def _month(when) -> str:
    return when.strftime('%Y-%m')


def _day(when):
    return when.date() if isinstance(when, dt.datetime) else when


# ── the queue (pure) ──────────────────────────────────────────────────────

def replay(events: Events) -> Replay:
    """First in, first out: each closing takes the oldest open riyals; each
    slice's result is the grams it bought less its share of the grams sold."""
    by_invoice = {lot.invoice_id: lot for lot in events.openings if lot.invoice_id is not None}
    ordered = ([(lot.when, 0, 'open', lot) for lot in events.openings]
               + [(r.when, 1, 'return', r) for r in events.returns]
               + [(c.when, 2, 'close', c) for c in events.closings]
               + [(d[0], 3, 'direct', d) for d in events.direct])
    ordered.sort(key=lambda e: (e[0], e[1]))

    queue = collections.deque()
    by_kind = collections.defaultdict(collections.Counter)
    by_month = collections.defaultdict(collections.Counter)
    month_end, unmatched, slices, anomalies = {}, [], [], collections.Counter()
    current = None

    def snapshot(m):
        month_end[m] = (sum(lot.cash_open for lot in queue), sum(lot.grams_open for lot in queue))

    for when, _, what, item in ordered:
        m = _month(when)
        if current is not None and m != current:
            snapshot(current)
        current = m
        if what == 'direct':
            by_month[m]['direct'] += item[1]
            by_kind['direct']['result'] += item[1]
        elif what == 'open':
            queue.append(item)
            by_month[m]['opened_cash'] += item.cash
            by_month[m]['opened_grams'] += item.grams
            if item.price_at_sale:
                by_month[m]['expected'] += item.cash / item.price_at_sale - item.grams
        elif what == 'return':
            lot = by_invoice.get(item.original_invoice_id)
            if lot is None or lot.cash_open < item.cash - 0.01:
                anomalies['a return of a sale already closed, or outside the period'] += 1
            if lot is not None:
                lot.cash_open = max(lot.cash_open - item.cash, 0.0)
                lot.grams_open = max(lot.grams_open - item.grams, 0.0)
        else:
            remaining = item.cash
            while remaining > 0.005 and queue:
                lot = queue[0]
                if lot.cash_open <= 0.005:
                    queue.popleft()
                    continue
                take = min(lot.cash_open, remaining)
                grams_out = lot.grams_open * take / lot.cash_open
                grams_in = item.grams * take / item.cash if item.cash else 0.0
                lot.cash_open -= take
                lot.grams_open -= grams_out
                remaining -= take
                slices.append(Slice(when, item.kind, take, grams_in, grams_out))
                for bucket in (by_month[m], by_kind[item.kind]):
                    bucket['cash'] += take
                    bucket['grams_in'] += grams_in
                    bucket['grams_out'] += grams_out
                    bucket['result'] += grams_in - grams_out
            if remaining > 0.005:
                # Riyals spent with none of the period's left open: cash on
                # hand from before turned into gold, or spent.
                unmatched.append(Closing(when, item.kind, remaining,
                                         item.grams * remaining / item.cash if item.cash else 0.0,
                                         item.invoice_id))
    if current is not None:
        snapshot(current)
    return Replay(list(events.openings), slices, sorted(events.direct, key=lambda d: d[0]), by_kind, by_month,
                  month_end, unmatched, anomalies)


def unrealized(cash_open: float, grams_open: float, price: float) -> float:
    """What the open riyals would buy at *price*, less the grams sold for them."""
    return (cash_open / price - grams_open) if price else 0.0


# ── the books ─────────────────────────────────────────────────────────────

def collect_events(start: dt.datetime, end: dt.datetime) -> Events:
    """Sources and uses from the posted books between *start* and *end*."""
    from accounting.balances import counted_line_filters
    from models import Account, Invoice, JournalEntry, JournalEntryLine, db
    from pricing.karat_service import get_main_karat
    from routes import _invoice_weight_in_main_karat
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
    from services.gram_profit_accounts import gram_profit_accounts
    from services.sales_vat import posted_sales_vat

    events = Events()
    invoices = (Invoice.query
                .filter(Invoice.is_posted.is_(True), Invoice.date >= start, Invoice.date <= end)
                .filter(db.func.coalesce(Invoice.status, '').notin_(list(RETRACTED_INVOICE_STATUSES)))
                .order_by(Invoice.date, Invoice.id).all())
    # A sale's VAT is what its posted entry carries -- not its total_tax field
    # (558k apart on the 2026 sales; ADR-048), as gram profit reads it.
    sales_vat = posted_sales_vat([inv.id for inv in invoices if inv.invoice_type in (SALE, SALE_RETURN)])
    for inv in invoices:
        kind = (inv.invoice_type or '').strip()
        if kind in (SALE, SALE_RETURN):
            cash = float(inv.total or 0) - sales_vat.get(inv.id, 0.0)
        else:
            cash = float(inv.total or 0) - float(inv.total_tax or 0)
        grams = _invoice_weight_in_main_karat(inv)
        if kind == SALE:
            events.openings.append(Lot(f'بيع #{inv.invoice_type_id}', inv.date, cash, grams,
                                       float(inv.profit_weight_price_per_gram or 0) or None, inv.id))
        elif kind == CUSTOMER_BUY_RETURN:      # gold given back for riyals: like a sale
            events.openings.append(Lot(f'مرتجع شراء #{inv.invoice_type_id}', inv.date, cash, grams, None, inv.id))
        elif kind == SALE_RETURN and inv.original_invoice_id:
            events.returns.append(Return(inv.date, inv.original_invoice_id, cash, grams))
        elif kind == CUSTOMER_BUY:
            events.closings.append(Closing(inv.date, CUSTOMER, cash, grams, inv.id))
        elif kind == PURCHASE and inv.office_id is not None:
            events.closings.append(Closing(inv.date, OFFICE, cash, grams, inv.id))
        else:
            # A supplier's gold is owed by weight and paid by weight: gold for
            # gold, no riyals turned. Its wages are the expense 510.
            events.skipped[kind or '?'] += 1

    # The revenues and expenses gram profit counts (the owner's marks), when entered.
    revenue_ids, expense_ids = gram_profit_accounts()
    marked = revenue_ids | expense_ids
    main_karat = float(get_main_karat() or 21)
    weight_accounts = {a.id for a in Account.query.filter(Account.id.in_(marked or {-1}),
                                                          Account.tracks_weight.is_(True))}
    rows = (db.session.query(JournalEntry.date, JournalEntryLine)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters())
            .filter(JournalEntryLine.account_id.in_(marked or {-1}),
                    JournalEntry.date >= start, JournalEntry.date <= end).all())
    per_day = collections.defaultdict(collections.Counter)
    for when, line in rows:
        credit_less_debit = float(line.cash_credit or 0) - float(line.cash_debit or 0)
        if line.account_id in revenue_ids:
            per_day[_day(when)]['revenue'] += credit_less_debit      # riyals in, no grams sold
        else:
            per_day[_day(when)]['expense'] -= credit_less_debit      # riyals out, no grams bought
        # A weight line is a weight result at once: credit adds, debit takes.
        karats = (18, 21, 22, 24) if line.account_id in weight_accounts else (21,)
        grams = sum((float(getattr(line, f'credit_{k}k', 0) or 0) - float(getattr(line, f'debit_{k}k', 0) or 0))
                    * k / main_karat for k in karats)
        if abs(grams) > 1e-6:
            events.direct.append((when, grams))
    for day, amounts in per_day.items():
        when = dt.datetime.combine(day, dt.time(23, 59))
        if amounts['revenue'] > 0.005:
            events.openings.append(Lot(f'إيرادات {day}', when, amounts['revenue'], 0.0))
        if amounts['expense'] > 0.005:
            events.closings.append(Closing(when, EXPENSE, amounts['expense']))
    return events


def purchase_price(until: dt.date, days: int = PURCHASE_PRICE_DAYS):
    """(price per gram of the main karat, where it came from): what the shop
    paid for customers' gold in the last *days* days -- else its last purchase."""
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


def year_start(day: dt.date) -> dt.datetime:
    """The queue starts with the financial year: one database per year (ADR-044)."""
    return dt.datetime(day.year, 1, 1)


def _replayed(until: dt.date) -> Replay:
    return replay(collect_events(year_start(until), dt.datetime.combine(until, dt.time.max)))


def position(as_of: dt.date) -> dict:
    """What waits to become gold on *as_of*, and what it would buy."""
    from pricing.gold_price_service import get_current_gold_price
    result = _replayed(as_of)
    lots = result.open_lots
    cash = sum(lot.cash_open for lot in lots)
    grams = sum(lot.grams_open for lot in lots)
    price, source = purchase_price(as_of)
    market = float(get_current_gold_price().get('price_per_gram_main_karat') or 0)
    return {
        'as_of': as_of.isoformat(),
        'open_cash': round(cash, 2), 'open_grams_sold': round(grams, 3),
        'purchase_price': round(price, 4), 'purchase_price_source': source,
        'unrealized': round(unrealized(cash, grams, price), 3),
        'market_price': round(market, 4), 'unrealized_at_market': round(unrealized(cash, grams, market), 3),
        'lots': [{'ref': lot.ref, 'invoice_id': lot.invoice_id, 'date': lot.when.isoformat(),
                  'cash': round(lot.cash, 2), 'cash_open': round(lot.cash_open, 2),
                  'grams_open': round(lot.grams_open, 3)} for lot in lots],
    }


def open_on(day: dt.date):
    """(open riyals, their grams sold) at the end of *day*."""
    lots = _replayed(day).open_lots
    return sum(lot.cash_open for lot in lots), sum(lot.grams_open for lot in lots)


def performance(start: dt.date, end: dt.date) -> dict:
    """The weight profit of *start*..*end* (inclusive): what was realized in
    it, the weight lines in it, and how the unrealized moved -- from the end
    of the day before *start* (nothing before the year) to the end of *end*."""
    result = _replayed(end)
    lo, hi = dt.datetime.combine(start, dt.time.min), dt.datetime.combine(end, dt.time.max)
    taken = [s for s in result.slices if lo <= s.when <= hi]
    by_kind = collections.Counter()
    for piece in taken:
        by_kind[piece.kind] += piece.result
    realized = sum(by_kind.values())
    direct = sum(g for when, g in result.direct if lo <= when <= hi)

    def unrealized_on(day: dt.date) -> float:
        if day < year_start(end).date():
            return 0.0
        cash, grams = open_on(day)
        price, _ = purchase_price(day)
        return unrealized(cash, grams, price)

    before = unrealized_on(start - dt.timedelta(days=1))
    after = unrealized_on(end)
    return {
        'start': start.isoformat(), 'end': end.isoformat(),
        'realized': round(realized, 3), 'direct': round(direct, 3),
        'unrealized_start': round(before, 3), 'unrealized_end': round(after, 3),
        'unrealized_change': round(after - before, 3),
        'weight_profit': round(realized + direct + after - before, 3),
        'realized_by_kind': {k: round(v, 3) for k, v in by_kind.items()},
    }
