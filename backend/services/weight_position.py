"""The weight position: a sale's riyals waiting to become gold again, and what turning them back made (ADR-048).

The owner, 16 Oct 2026: the shop measures itself in gold; cash is a passing
state. A sale turns grams into riyals; a cash purchase of gold, or a marked
expense, turns them back -- first in, first out, by the riyal. What the
riyals bought back, less what was sold for them, is the weight profit:
realized when they are spent, unrealized while they wait -- valued at the
closing office's price now, against the price of their own sales (ADR-048
decision 5, restated 23 Oct and again 2 Nov 2026: «أفضل للتسكيرات ان يكون
السعر هو سعر المكتب وليس سعر المكتب ×0.99 عكس شراء كسر»; it was the scrap
price, and before it the shop's purchase average of 7 days).

Derived from the posted books, never stored: an edit, a return or an
unposting changes the books, and the next reading follows. Three parts:

  collect_events(start, end)  -- the sources and uses, from invoices and the
                                 marked revenue/expense lines;
  replay(events)              -- the queue (pure: no database);
  position(as_of) / performance(start, end) -- the two views;
  sale_closing(invoice_id, as_of)            -- one sale: where its riyals went.
"""
from __future__ import annotations

import collections
import datetime as dt
from dataclasses import dataclass, field

SALE, SALE_RETURN, CUSTOMER_BUY, CUSTOMER_BUY_RETURN = 'بيع', 'مرتجع بيع', 'شراء من عميل', 'مرتجع شراء'
PURCHASE, SUPPLIER_RETURN = 'شراء', 'مرتجع شراء (مورد)'

# What closes: a customer's gold bought, an office's reservation settled, a marked expense.
CUSTOMER, OFFICE, EXPENSE = 'customer', 'office', 'expense'
# What opens: a sale (or gold given back to a customer for riyals), a marked revenue.
SOLD, REVENUE = 'sold', 'revenue'
# A weight line's side.
REVENUE_SIDE, EXPENSE_SIDE = 'revenue', 'expense'
PURCHASE_PRICE_DAYS = 7          # the window of what the shop paid, shown beside (the owner, 16 Oct 2026)
RECENT_DAYS = 3                  # the manager's card: what waits up to 3 days is recent


@dataclass
class Lot:
    """An opening: riyals in, grams out (none for a revenue)."""
    ref: str
    when: dt.datetime
    cash: float
    grams: float
    price_at_sale: float | None = None  # the office's price it was sold at: its closing price (decision 5)
    invoice_id: int | None = None
    kind: str = SOLD
    cash_open: float = field(init=False)
    grams_open: float = field(init=False)
    returned_cash: float = field(init=False, default=0.0)    # what its returns took off the open riyals
    returned_grams: float = field(init=False, default=0.0)

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
    tag: tuple | None = None          # a period expense's: (expense id, 'prepaid' | 'accrued') -- ADR-090 law 11


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
    direct: list = field(default_factory=list)       # (when, grams, side): a weight line, a result at once
    skipped: collections.Counter = field(default_factory=collections.Counter)
    # ADR-090 law 11, a period expense's riyals: (when, tag, riyals) back to waiting -- a payment
    # cancelled, an accrual taken back -- with the grams they took; and (when, expense id, riyals)
    # of a prepaid payment drawn by a month (negative: put back), its grams that month's.
    restores: list = field(default_factory=list)
    draws: list = field(default_factory=list)


@dataclass
class Slice:
    """A closing's take from one lot: riyals, grams bought with them, the lot's grams sold for them."""
    when: dt.datetime
    kind: str
    cash: float
    grams_in: float
    grams_out: float
    lot_kind: str = SOLD
    invoice_id: int | None = None                     # the closing's invoice; none for an expense
    lot_invoice_id: int | None = None                 # the sale whose riyals it took
    tag: tuple | None = None                          # a period expense's closing (ADR-090 law 11)
    spent_at: dt.datetime | None = None               # a prepaid piece: the day its riyals were spent

    @property
    def result(self) -> float:
        return self.grams_in - self.grams_out

    @property
    def happened(self) -> dt.datetime:
        """When its riyals left: the payment's day for a prepaid piece dated by the month it serves."""
        return self.spent_at or self.when


@dataclass
class Replay:
    lots: list
    slices: list
    direct: list                                      # (when, grams, side)
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
               + [(d[0], 3, 'direct', d) for d in events.direct]
               + [(r[0], 4, 'restore', r) for r in events.restores])
    ordered.sort(key=lambda e: (e[0], e[1]))

    # Two queues, each first in first out. Which riyals a closing takes does
    # not change the whole (the grams bought and the riyals left open are what
    # they are) -- only how it reads by layer: an expense spends the riyals of
    # what was sold first (④ is the grams sold it spent), a purchase turns a
    # revenue's riyals into gold first (② is what the revenues bought).
    queues = {SOLD: collections.deque(), REVENUE: collections.deque()}
    order = {EXPENSE: (SOLD, REVENUE)}
    by_kind = collections.defaultdict(collections.Counter)
    by_month = collections.defaultdict(collections.Counter)
    month_end, unmatched, slices, anomalies = {}, [], [], collections.Counter()
    current = None

    def snapshot(m):
        lots = [lot for q in queues.values() for lot in q]
        month_end[m] = (sum(lot.cash_open for lot in lots), sum(lot.grams_open for lot in lots))

    for when, _, what, item in ordered:
        m = _month(when)
        if current is not None and m != current:
            snapshot(current)
        current = m
        if what == 'direct':
            by_month[m]['direct'] += item[1]
            by_kind['direct']['result'] += item[1]
        elif what == 'restore':
            _restore(item, slices, queues, anomalies, by_month, by_kind)
        elif what == 'open':
            queues[REVENUE if item.kind == REVENUE else SOLD].append(item)
            by_month[m]['opened_cash'] += item.cash
            by_month[m]['opened_grams'] += item.grams
            if item.price_at_sale:
                by_month[m]['expected'] += item.cash / item.price_at_sale - item.grams
        elif what == 'return':
            lot = by_invoice.get(item.original_invoice_id)
            if lot is None or lot.cash_open < item.cash - 0.01:
                anomalies['a return of a sale already closed, or outside the period'] += 1
            if lot is not None:
                cash_open, grams_open = lot.cash_open, lot.grams_open
                lot.cash_open = max(lot.cash_open - item.cash, 0.0)
                lot.grams_open = max(lot.grams_open - item.grams, 0.0)
                lot.returned_cash += cash_open - lot.cash_open
                lot.returned_grams += grams_open - lot.grams_open
        else:
            remaining = item.cash
            for queue in (queues[k] for k in order.get(item.kind, (REVENUE, SOLD))):
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
                    slices.append(Slice(when, item.kind, take, grams_in, grams_out, lot.kind, item.invoice_id,
                                         lot.invoice_id, tag=item.tag))
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
    slices = _dated_by_their_months(slices, events.draws, by_month, by_kind)
    return Replay(list(events.openings), slices, sorted(events.direct, key=lambda d: d[0]), by_kind, by_month,
                  month_end, unmatched, anomalies)


# A prepaid piece no month has drawn yet: spent, its grams waiting for the
# months it serves -- in no period that has ended (ADR-090 law 11).
NOT_YET_DRAWN = dt.datetime.max


def _count(by_month, by_kind, piece, sign: float) -> None:
    """A piece's riyals and grams in its month's and its kind's counters (sign -1: taken off)."""
    buckets = [by_kind[piece.kind]] + ([by_month[_month(piece.when)]] if piece.when != NOT_YET_DRAWN else [])
    for bucket in buckets:
        bucket['cash'] += sign * piece.cash
        bucket['grams_in'] += sign * piece.grams_in
        bucket['grams_out'] += sign * piece.grams_out
        bucket['result'] += sign * piece.result


def _restore(item, slices, queues, anomalies, by_month, by_kind) -> None:
    """A period expense's riyals back to waiting (a payment cancelled, an
    accrual taken back): taken off its latest pieces, each back as the lot it
    came from, with the grams it took -- as if they had never left."""
    when, tag, cash = item
    remaining = cash
    for piece in reversed(slices):
        if remaining <= 0.005:
            break
        if piece.tag != tag or piece.cash <= 0.005:
            continue
        take = min(piece.cash, remaining)
        grams_back = piece.grams_out * take / piece.cash
        _count(by_month, by_kind, piece, -1)
        piece.grams_out -= grams_back
        piece.cash -= take
        remaining -= take
        _count(by_month, by_kind, piece, +1)
        lot = Lot(f'استرداد مصروف فترة #{tag[0]}', when, take, grams_back, None, piece.lot_invoice_id,
                  kind=piece.lot_kind)
        queues[REVENUE if lot.kind == REVENUE else SOLD].append(lot)
    if remaining > 0.005:
        anomalies['a period expense\'s riyals back with none of its pieces to take them from'] += 1


def _dated_by_their_months(slices, draws, by_month, by_kind):
    """Each prepaid payment's pieces, dated by the months that draw them,
    first paid first drawn (a negative draw puts the latest drawn back); what
    no month has drawn yet stays NOT_YET_DRAWN (ADR-090 law 11)."""
    import dataclasses
    by_expense = collections.defaultdict(list)
    for piece in slices:
        if piece.tag is not None and piece.tag[1] == 'prepaid' and piece.cash > 0.005:
            by_expense[piece.tag[0]].append(piece)
    if not by_expense:
        return slices
    drawn_of = collections.defaultdict(list)            # expense -> its pieces drawn, in order
    pending_of = {pe: [dataclasses.replace(p, spent_at=p.when, when=NOT_YET_DRAWN) for p in pieces]
                  for pe, pieces in by_expense.items()}
    for when, pe, cash in sorted(draws, key=lambda d: d[0]):
        by_month[_month(when)]                          # the month is read, even with nothing else in it
        pending, drawn = pending_of.get(pe, []), drawn_of[pe]
        if cash > 0:
            remaining = cash
            while remaining > 0.005 and pending:
                piece = pending[0]
                take = min(piece.cash, remaining)
                share = take / piece.cash
                drawn.append(dataclasses.replace(piece, when=when, cash=take, grams_in=piece.grams_in * share,
                                                 grams_out=piece.grams_out * share))
                piece.grams_in -= piece.grams_in * share
                piece.grams_out -= piece.grams_out * share
                piece.cash -= take
                remaining -= take
                if piece.cash <= 0.005:
                    pending.pop(0)
        else:
            remaining = -cash
            while remaining > 0.005 and drawn:
                piece = drawn[-1]
                take = min(piece.cash, remaining)
                share = take / piece.cash
                pending.insert(0, dataclasses.replace(piece, when=NOT_YET_DRAWN, cash=take,
                                                      grams_in=piece.grams_in * share,
                                                      grams_out=piece.grams_out * share))
                piece.grams_in -= piece.grams_in * share
                piece.grams_out -= piece.grams_out * share
                piece.cash -= take
                remaining -= take
                if piece.cash <= 0.005:
                    drawn.pop()
    for pieces in by_expense.values():                  # off the months they were spent in
        for piece in pieces:
            _count(by_month, by_kind, piece, -1)
    for piece in [p for pieces in drawn_of.values() for p in pieces]:   # onto the months that drew them
        _count(by_month, by_kind, piece, +1)
    redated = {id(p) for pieces in by_expense.values() for p in pieces}
    kept = [p for p in slices if id(p) not in redated]
    return kept + [p for pieces in drawn_of.values() for p in pieces] \
        + [p for pieces in pending_of.values() for p in pieces]


def sale_view(result: Replay, events: Events, invoice_id: int, price: float) -> dict | None:
    """One sale: its riyals, and where each went -- back with a return, into
    what closed it (first in, first out), or still waiting. The pairing is the
    queue's, read from the books each time, not frozen (ADR-048 phase 3a)."""
    lot = next((lot for lot in result.lots if lot.invoice_id == invoice_id), None)
    if lot is None:
        return None
    returned = [r for r in events.returns if r.original_invoice_id == invoice_id]
    taken = [piece for piece in result.slices if piece.lot_invoice_id == invoice_id]
    closed_cash = sum(piece.cash for piece in taken)
    waiting = lot.cash_open > 0.005
    status = ('partially_closed' if waiting and taken else 'open' if waiting
              else 'closed' if taken else 'cancelled')
    return {
        'invoice_id': invoice_id, 'date': lot.when.isoformat(), 'status': status,
        'cash': round(lot.cash, 2), 'grams': round(lot.grams, 3),
        'expected_at_sale': round(lot.cash / lot.price_at_sale - lot.grams, 3) if lot.price_at_sale else None,
        # A return takes off what is still open; one after the riyals turned
        # into gold took none of them, and is shown apart (as 881 on the copy).
        'returned_cash': round(lot.returned_cash, 2), 'returned_grams': round(lot.returned_grams, 3),
        'returned_after_closing_cash': round(max(sum(r.cash for r in returned) - lot.returned_cash, 0.0), 2),
        'closed_cash': round(closed_cash, 2), 'cash_open': round(lot.cash_open, 2),
        # Each part's share of the sale's riyals -- the card's bar.
        'shares': {name: (round(part / lot.cash, 4) if lot.cash else 0.0) for name, part in
                   (('closed', closed_cash), ('returned', lot.returned_cash), ('open', lot.cash_open))},
        'grams_open': round(lot.grams_open, 3),
        'closings': [{'date': piece.happened.isoformat(), 'kind': piece.kind, 'invoice_id': piece.invoice_id,
                      'cash': round(piece.cash, 2), 'grams_in': round(piece.grams_in, 3),
                      'grams_out': round(piece.grams_out, 3), 'result': round(piece.result, 3)}
                     for piece in taken],
        'realized': round(sum(piece.result for piece in taken), 3),
        'unrealized': round(unrealized(lot.cash_open, lot.grams_open, price), 3),
    }


def split_layers(slices, direct) -> dict:
    """The weight profit by layer (the owner, 16 Oct 2026: five, not four).

    ① trading         riyals of what was sold that became gold
    ② revenue         a marked revenue's riyals that became gold, and its weight lines
    ③ expense_direct  marked expenses booked in weight
    ④ expense_cash    marked cash expenses: the grams sold whose riyals they spent
    ⑤ price_effect    (added by the caller) how the waiting riyals' worth moved
    """
    return {
        'trading': sum(s.result for s in slices if s.kind != EXPENSE and s.lot_kind != REVENUE),
        'revenue_converted': sum(s.result for s in slices if s.kind != EXPENSE and s.lot_kind == REVENUE),
        'revenue_direct': sum(d[1] for d in direct if d[2] == REVENUE_SIDE),
        'expense_direct': sum(d[1] for d in direct if d[2] == EXPENSE_SIDE),
        'expense_cash': sum(s.result for s in slices if s.kind == EXPENSE),
    }


def unrealized(cash_open: float, grams_open: float, price: float) -> float:
    """What the open riyals would buy at *price*, less the grams sold for them."""
    return (cash_open / price - grams_open) if price else 0.0


# ── the books ─────────────────────────────────────────────────────────────

def _with_weight_lines(query):
    """An invoice's weight is read from its karat lines or items: load them with
    the invoices, not one query per invoice (8,073 of them made a day's gram
    profit take 3 s on the production copy, 16 Oct 2026)."""
    from sqlalchemy.orm import selectinload
    from models import Invoice
    return query.options(selectinload(Invoice.karat_lines), selectinload(Invoice.items))


def _until(events: Events, moment: dt.datetime) -> Events:
    """The events up to *moment*, as fresh lots: the queue replays them again
    without reading the books again (replay consumes its lots)."""
    import dataclasses
    return Events(openings=[dataclasses.replace(lot) for lot in events.openings if lot.when <= moment],
                  closings=[c for c in events.closings if c.when <= moment],
                  returns=[r for r in events.returns if r.when <= moment],
                  direct=[d for d in events.direct if d[0] <= moment],
                  restores=[r for r in events.restores if r[0] <= moment],
                  draws=[d for d in events.draws if d[0] <= moment])


def collect_events(start: dt.datetime, end: dt.datetime) -> Events:
    """Sources and uses from the posted books between *start* and *end*."""
    from accounting.balances import counted_line_filters
    from models import Account, Invoice, JournalEntry, JournalEntryLine, db
    from pricing.karat_service import get_main_karat
    from routes import _invoice_weight_in_main_karat
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
    from services.gram_profit_accounts import gram_profit_accounts
    from services.sales_vat import posted_sales_vat

    from pricing.buy_price import buy_price_ratio
    ratio = buy_price_ratio()
    events = Events()
    invoices = (_with_weight_lines(Invoice.query)
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
            # The price it was sold at, kept when it was recorded. One kept
            # with a scrap price (23 Oct - 2 Nov 2026, all at 0.99; those
            # waiting from before the office's terms re-priced at the office)
            # is read back by the ratio.
            scrap = float(inv.scrap_buy_price_at_sale or 0)
            price = (scrap / ratio if scrap and ratio else float(inv.profit_weight_price_per_gram or 0)) or None
            events.openings.append(Lot(f'بيع #{inv.invoice_type_id}', inv.date, cash, grams, price, inv.id))
        elif kind == CUSTOMER_BUY_RETURN:      # gold given back for riyals: like a sale
            events.openings.append(Lot(f'مرتجع شراء كسر #{inv.invoice_type_id}', inv.date, cash, grams, None, inv.id))
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

    events.openings.extend(_gold_taken_from_salaries(start, end))
    events.openings.extend(opening_lot(start, end))

    # The revenues and expenses gram profit counts (the owner's marks), when entered.
    revenue_ids, expense_ids = gram_profit_accounts()
    marked = revenue_ids | expense_ids
    main_karat = float(get_main_karat())
    weight_accounts = {a.id for a in Account.query.filter(Account.id.in_(marked or {-1}),
                                                          Account.tracks_weight.is_(True))}
    rows = (db.session.query(JournalEntry.date, JournalEntryLine)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters())
            .filter(JournalEntryLine.account_id.in_(marked or {-1}),
                    JournalEntry.date >= start, JournalEntry.date <= end,
                    # a period expense's months: read from the expense itself, below (ADR-090 law 11)
                    db.func.coalesce(JournalEntry.reference_type, '') != PERIOD_EXPENSE_MONTH).all())
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
            events.direct.append((when, grams, REVENUE_SIDE if line.account_id in revenue_ids else EXPENSE_SIDE))
    for day, amounts in per_day.items():
        when = dt.datetime.combine(day, dt.time(23, 59))
        if amounts['revenue'] > 0.005:
            events.openings.append(Lot(f'إيرادات {day}', when, amounts['revenue'], 0.0, kind=REVENUE))
        if amounts['expense'] > 0.005:
            events.closings.append(Closing(when, EXPENSE, amounts['expense']))
    _period_expense_events(events, start, end, expense_ids)
    return events


PERIOD_EXPENSE_MONTH = 'period_expense'            # services/period_expense.MONTH_ENTRY


def period_expense_timeline(payments, months) -> tuple[list, list, list]:
    """One period expense's riyals in the queue (ADR-090 law 11), pure.

    *payments*: (day, voucher id, halalas, the day it was cancelled or None);
    *months*: (month-end day, halalas) its month entries posted, signed.
    The riyals out of waiting by any moment are the larger of what was paid
    and what was accrued: a payment ahead of the accruals spends them that
    day (prepaid); an accrual beyond the payments spends them at its month's
    end (accrued); an accrual within what was paid spends nothing -- it draws
    the prepaid, its grams that month's. What falls back -- a payment
    cancelled, an accrual taken back -- returns to waiting with its grams.

    Returns (closings, restores, draws), each (day, ...), in halalas:
    closings (day, kind, h), restores (day, kind, h), draws (day, h)."""
    timeline = []
    for day, _, h, stopped in payments:
        timeline.append((day, 0, 'pay', h))
        if stopped is not None:
            timeline.append((stopped, 1, 'pay', -h))
    for day, h in months:
        timeline.append((day, 2, 'accrue', h))         # a month's after that day's payments
    timeline.sort(key=lambda t: (t[0], t[1]))
    paid = posted = 0
    closings, restores, draws = [], [], []
    for day, _, what, h in timeline:
        before = max(paid, posted)
        if what == 'pay':
            paid += h
        else:
            posted += h
        delta = max(paid, posted) - before
        if what == 'pay':
            if delta > 0:
                closings.append((day, 'prepaid', delta))
            elif delta < 0:
                restores.append((day, 'prepaid', -delta))
            continue
        if h > 0:
            if delta > 0:
                closings.append((day, 'accrued', delta))
            if h - delta > 0:
                draws.append((day, h - delta))
        else:
            if delta < 0:
                restores.append((day, 'accrued', -delta))
            if -h + delta > 0:
                draws.append((day, -(-h + delta)))     # put back: a prepaid month not consumed after all
    return closings, restores, draws


def _period_expense_events(events: Events, start: dt.datetime, end: dt.datetime, expense_ids: set) -> None:
    """The period expenses on a marked account, as the queue reads them (ADR-090 law 11)."""
    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, PeriodExpense, db
    from services.period_expense import _payments, halalas

    def at(day):
        return dt.datetime.combine(day, dt.time(23, 59))

    for pe in PeriodExpense.query.filter(PeriodExpense.expense_account_id.in_(expense_ids or {-1})).all():
        rows = (db.session.query(JournalEntry.date, JournalEntryLine.cash_debit, JournalEntryLine.cash_credit)
                .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                .filter(*counted_line_filters(), JournalEntry.reference_type == PERIOD_EXPENSE_MONTH,
                        JournalEntry.reference_id == pe.id, JournalEntryLine.account_id == pe.expense_account_id)
                .all())
        months = [(_day(d), halalas((debit or 0) - (credit or 0))) for d, debit, credit in rows]
        closings, restores, draws = period_expense_timeline(_payments(pe), months)
        for day, kind, h in closings:
            if start <= at(day) <= end:
                events.closings.append(Closing(at(day), EXPENSE, h / 100, tag=(pe.id, kind)))
        for day, kind, h in restores:
            if start <= at(day) <= end:
                events.restores.append((at(day), (pe.id, kind), h / 100))
        for day, h in draws:
            if start <= at(day) <= end:
                events.draws.append((at(day), pe.id, h / 100))


def carried_cash(waiting_cash, to_gold_cash) -> float:
    """The riyals a year starts with waiting: what waited at the count less
    what customers opened as gold -- nothing below zero (a closing past the
    queue is unmatched, ADR-048)."""
    return max(round(float(waiting_cash or 0) - float(to_gold_cash or 0), 2), 0.0)


def opening_lot(start: dt.datetime, end: dt.datetime) -> list:
    """The year before's riyals still waiting, carried in at the count price
    (ADR-044 decision 1: «تنتقل منتظرة بسعر الجرد»): one lot on the year's
    first moment -- what waited at the count, less what customers opened as
    gold -- priced at the count day's closing price, so nothing is
    expected of it there; what comes after is this year's. Frozen on the
    opening's approval (services/opening_figures.approve); read only when the
    queue starts with the year."""
    from models import OpeningApproval, db
    first = year_start(start.date())
    if not (start <= first <= end):
        return []
    approval = db.session.get(OpeningApproval, first.year)
    if approval is None or not approval.closing_price:
        return []
    cash = carried_cash(approval.waiting_cash, approval.to_gold_cash)
    if cash <= 0.005:
        return []
    price = float(approval.closing_price)
    return [Lot(f'ريالات {first.year - 1} المنتظرة', first, cash, round(cash / price, 3), price)]


def _gold_taken_from_salaries(start: dt.datetime, end: dt.datetime) -> list:
    """An employee's gold advance taken from his salary in riyals (PAY-GOLD,
    ADR-082): riyals in for grams gone, booked as a purchase return -- an
    opening as a sale is, at the price it was taken at. From the approved
    salary vouchers' purchase-returns lines."""
    from accounting.mappings import get_account_id_for_mapping
    from models import Account, Voucher, VoucherAccountLine, db
    from pricing.gold_price_service import get_main_karat
    from services.payroll_payment import GOLD_TAKEN
    returns_id = get_account_id_for_mapping(*GOLD_TAKEN)
    returns = db.session.get(Account, returns_id) if returns_id else None
    if returns is None or not returns.memo_account_id:
        return []
    main = float(get_main_karat())
    rows = (db.session.query(Voucher, VoucherAccountLine)
            .join(VoucherAccountLine, VoucherAccountLine.voucher_id == Voucher.id)
            .filter(Voucher.reference_type == 'payroll', Voucher.status == 'approved',
                    Voucher.date >= start, Voucher.date <= end,
                    VoucherAccountLine.account_id.in_([returns.id, returns.memo_account_id])).all())
    taken = collections.defaultdict(lambda: [None, 0.0, 0.0])        # voucher id -> [voucher, riyals, grams]
    for voucher, line in rows:
        part = taken[voucher.id]
        part[0] = voucher
        if line.account_id == returns.id and line.line_type == 'credit' and line.amount_type == 'cash':
            part[1] += float(line.amount or 0.0)
        elif line.account_id == returns.memo_account_id and line.line_type == 'debit' and line.amount_type == 'gold':
            part[2] += float(line.amount or 0.0) * float(line.karat or main) / main
    return [Lot(f'سلفة ذهب {voucher.party_name or ""}'.strip(), voucher.date, cash, grams, cash / grams)
            for voucher, cash, grams in taken.values() if cash > 0.005 and grams > 1e-6]


def office_prices(until: dt.date):
    """price_on(day) -> (the closing office's price per gram of the main
    karat, where it came from), for any day up to *until*: the day's last
    price -- the rule a sale keeps its own by; no buy ratio, which is a
    customer's scrap (the owner, 2 Nov 2026). A day with no new price keeps
    the last; before any price, nothing. One reading."""
    import bisect
    from models import GoldPrice, db
    from pricing.gold_price_service import get_main_karat
    from pricing.office_price import row_gram_price
    end = dt.datetime.combine(until, dt.time.max)
    last = (db.session.query(db.func.max(GoldPrice.date).label('at'))
            .filter(GoldPrice.date <= end).group_by(db.func.date(GoldPrice.date)).subquery())
    rows = GoldPrice.query.filter(GoldPrice.date.in_(db.select(last.c.at))).order_by(GoldPrice.date).all()
    days = [row.date.date() for row in rows]
    main = int(get_main_karat())
    # The closing office's, each day by the terms it was saved with (OFFICE-PRICE-1).
    markets = [row_gram_price(row, main) for row in rows]

    def price_on(day: dt.date):
        at = bisect.bisect_right(days, day) - 1
        if at < 0 or not markets[at]:
            return 0.0, 'لا سعر'
        return markets[at], 'سعر التسكير'
    return price_on


def closing_price(lots) -> float | None:
    """The open sales' prices, weighted by their grams still waiting
    (the owner: 1 g at 440, 1 g at 435, 1 g at 430 close at 435)."""
    priced = [lot for lot in lots if lot.price_at_sale and lot.grams_open > 0]
    grams = sum(lot.grams_open for lot in priced)
    return sum(lot.grams_open * lot.price_at_sale for lot in priced) / grams if grams else None


def unrealized_parts(lots, price: float) -> tuple[float, float]:
    """What waits, in two (the owner, 2 Nov 2026): what its sales make at
    their own closing price, and the price's move since. None priced: it
    is all its sales'."""
    cash, grams = sum(lot.cash_open for lot in lots), sum(lot.grams_open for lot in lots)
    now = unrealized(cash, grams, price)
    closing = closing_price(lots)
    if not closing:
        return now, 0.0
    expected = unrealized(cash, grams, closing)
    return expected, now - expected


def purchase_prices(until: dt.date, days: int = PURCHASE_PRICE_DAYS):
    """price_on(day) -> (price per gram of the main karat, where it came from),
    for any day up to *until*: what the shop paid for customers' gold on its
    last *days* days that had a purchase, from one reading of the purchases.

    Purchase days, not calendar days: a day with no purchase moves nothing
    (16 Oct 2026: a quiet day showed -10 g only because an old day left a
    calendar window). From the invoices alone -- no live feed."""
    import bisect
    from models import Invoice
    from routes import _invoice_weight_in_main_karat
    end = dt.datetime.combine(until, dt.time.max)
    per_day = collections.defaultdict(list)                  # day -> [(cash, grams)], latest first
    for inv in (_with_weight_lines(Invoice.query).filter(Invoice.invoice_type == CUSTOMER_BUY,
                                                         Invoice.is_posted.is_(True), Invoice.date <= end)
                .order_by(Invoice.date.desc())):
        per_day[inv.date.date()].append((float(inv.total or 0), _invoice_weight_in_main_karat(inv)))
    ordered = sorted(per_day)

    def price_on(day: dt.date):
        at = bisect.bisect_right(ordered, day)
        window = ordered[max(at - days, 0):at]
        if not window:
            return 0.0, 'لا شراء'
        rows = [row for d in reversed(window) for row in per_day[d]]
        cash, grams = sum(r[0] for r in rows), sum(r[1] for r in rows)
        return ((cash / grams if grams else 0.0),
                f'متوسط شراء الكسر في آخر {len(window)} أيام شراء ({window[0]:%m-%d} إلى {window[-1]:%m-%d})')
    return price_on


def purchase_price(until: dt.date, days: int = PURCHASE_PRICE_DAYS):
    """(price, where it came from) on *until* -- see purchase_prices."""
    return purchase_prices(until, days)(until)


def year_start(day: dt.date) -> dt.datetime:
    """The queue starts with the financial year: one database per year (ADR-044)."""
    return dt.datetime(day.year, 1, 1)


def _replayed(until: dt.date) -> Replay:
    return replay(collect_events(year_start(until), dt.datetime.combine(until, dt.time.max)))


def _where_the_riyals_are() -> dict:
    """Beside the position, not a split of it: the riyals in hand, with the
    customers, with the employees (the owner, 16 Oct 2026: a loan or an
    advance is riyals still waiting, not spent)."""
    from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT, role_subtree_ids
    from models import SafeBox
    from services.employee_accounts import PERSONAL_PARENT
    from services.live_balances import live_balances_by_account_ids

    def cash_of(ids):
        ids = set(ids or ())
        return round(sum(b['cash'] for b in live_balances_by_account_ids(ids).values()), 2) if ids else 0.0
    money = {sb.account_id for sb in SafeBox.query.filter(SafeBox.safe_type.in_(('cash', 'bank')),
                                                          SafeBox.is_active.is_(True)) if sb.account_id}
    try:
        employees = role_subtree_ids(PERSONAL_PARENT)
    except Exception:
        employees = set()
    return {'in_hand': cash_of(money), 'with_customers': cash_of(role_subtree_ids(CUSTOMER_RECEIVABLES_ROOT)),
            'with_employees': cash_of(employees)}


def against_closing_price(lots, cash: float, grams: float, price: float, source: str) -> dict:
    """What waits, against its closing price and the office's price now:
    expected at the closing price (its sales' own profit) plus the price's
    move since is what closing now would make."""
    closing = closing_price(lots)
    sales, moved = unrealized_parts(lots, price)
    expected = sales if closing else None
    now = sales + moved
    return {
        'closing_price': round(closing, 4) if closing else None,
        'price_now': round(price, 4), 'price_now_source': source,
        'buys_now_grams': round(cash / price, 3) if price else None,
        'expected_at_closing_price': round(expected, 3) if expected is not None else None,
        'price_effect_since_sale': round(now - expected, 3) if expected is not None else None,
        'unrealized': round(now, 3),
    }


def position(as_of: dt.date) -> dict:
    """What waits to become gold on *as_of*, what it would buy, and what closed lately."""
    from models import Customer, Invoice
    from pricing.gold_price_service import get_current_gold_price
    result = _replayed(as_of)
    lots = sorted(result.open_lots, key=lambda lot: lot.when)
    cash = sum(lot.cash_open for lot in lots)
    grams = sum(lot.grams_open for lot in lots)
    price, source = office_prices(as_of)(as_of)
    paid, paid_source = purchase_price(as_of)
    market = float(get_current_gold_price().get('price_per_gram_main_karat') or 0)
    invoices = {inv.id: inv for inv in Invoice.query.filter(
        Invoice.id.in_({lot.invoice_id for lot in lots if lot.invoice_id} or {-1}))}
    customers = {c.id: c.name for c in Customer.query.filter(
        Customer.id.in_({inv.customer_id for inv in invoices.values() if inv.customer_id} or {-1}))}
    end = dt.datetime.combine(as_of, dt.time.max)

    def lot_row(lot):
        inv = invoices.get(lot.invoice_id)
        return {'ref': lot.ref, 'kind': lot.kind, 'invoice_id': lot.invoice_id,
                'invoice_number': getattr(inv, 'invoice_type_id', None),
                'customer': customers.get(getattr(inv, 'customer_id', None)),
                'date': lot.when.isoformat(), 'age_days': (end - lot.when).days,
                'cash': round(lot.cash, 2), 'cash_open': round(lot.cash_open, 2),
                'grams_open': round(lot.grams_open, 3),
                'expected_at_sale': (round(lot.cash / lot.price_at_sale - lot.grams, 3)
                                     if lot.price_at_sale else None),
                'closing_price': round(lot.price_at_sale, 4) if lot.price_at_sale else None,
                'unrealized': round(unrealized(lot.cash_open, lot.grams_open, price), 3)}

    closings = collections.OrderedDict()
    for piece in sorted(result.slices, key=lambda p: p.happened, reverse=True):
        key = (piece.kind, piece.invoice_id or piece.happened.date())
        row = closings.setdefault(key, {'kind': piece.kind, 'invoice_id': piece.invoice_id,
                                        'date': piece.happened.isoformat(), 'cash': 0.0, 'grams_in': 0.0,
                                        'grams_out': 0.0, 'result': 0.0})
        for name in ('cash', 'grams_in', 'grams_out'):
            row[name] += getattr(piece, name)
        row['result'] += piece.result
        if len(closings) > 20:
            closings.popitem()
            break
    recent = [{k: (round(v, 3) if isinstance(v, float) else v) for k, v in row.items()} for row in closings.values()]

    return {
        'as_of': as_of.isoformat(),
        'open_cash': round(cash, 2), 'open_grams_sold': round(grams, 3), 'open_count': len(lots),
        **against_closing_price(lots, cash, grams, price, source),
        'paid_average': round(paid, 4), 'paid_average_source': paid_source,
        'market_price': round(market, 4),
        # Each 1 % the purchase price rises takes this many grams off the unrealized.
        'grams_per_price_percent': round((cash / price - cash / (price * 1.01)) if price else 0.0, 3),
        'oldest': lots[0].when.isoformat() if lots else None,
        'lots': [lot_row(lot) for lot in lots],
        'recent_closings': recent,
        'where_the_riyals_are': _where_the_riyals_are(),
    }


def summary(as_of: dt.date) -> dict:
    """The manager's card: what waits on *as_of*, what it buys at the shop's
    price, the price's grip on it, how long the oldest has waited -- with the
    owner's alert past his days (policy) -- and the month realized so far."""
    from accounting.weight_closing import _load_weight_closing_settings
    hi = dt.datetime.combine(as_of, dt.time.max)
    events = collect_events(year_start(as_of), hi)
    prices = office_prices(as_of)
    lots = sorted(replay(_until(events, hi)).open_lots, key=lambda lot: lot.when)
    cash = sum(lot.cash_open for lot in lots)
    grams = sum(lot.grams_open for lot in lots)
    price, source = prices(as_of)
    oldest_days = (hi - lots[0].when).days if lots else None
    limit = int(_load_weight_closing_settings().get('position_oldest_alert_days') or 7)
    month = performance(as_of.replace(day=1), as_of, events, prices)
    # What waits, by age, cut at 3 days and at the owner's alert days.
    recent_to = min(RECENT_DAYS, limit)
    cuts = [('recent', 0, recent_to)] + ([('aging', recent_to + 1, limit)] if limit > recent_to else []) \
        + [('late', limit + 1, None)]
    buckets = []
    for key, lo, hi_days in cuts:
        part = [lot for lot in lots if lo <= (hi - lot.when).days and (hi_days is None or (hi - lot.when).days <= hi_days)]
        part_cash = sum(lot.cash_open for lot in part)
        buckets.append({'key': key, 'from_days': lo, 'to_days': hi_days, 'cash': round(part_cash, 2),
                        'count': len(part), 'share': round(part_cash / cash, 4) if cash else 0.0})
    return {
        'as_of': as_of.isoformat(),
        'open_cash': round(cash, 2), 'open_count': len(lots),
        **against_closing_price(lots, cash, grams, price, source),
        'grams_per_price_percent': round((cash / price - cash / (price * 1.01)) if price else 0.0, 3),
        'oldest_date': lots[0].when.isoformat() if lots else None, 'oldest_age_days': oldest_days,
        'alert': {'oldest_over_days': limit, 'raised': oldest_days is not None and oldest_days > limit},
        'age_buckets': buckets,
        # What the month turned back into gold so far: realized and the weight lines, not ⑤.
        'month_realized': round(month['realized'] + month['direct'], 3),
    }


def sale_closing(invoice_id: int, as_of: dt.date) -> dict | None:
    """One standing sale, replayed in its own year up to *as_of*; None for
    anything else (a purchase, a held or rejected sale)."""
    from models import Invoice, db
    inv = db.session.get(Invoice, invoice_id)
    if inv is None or (inv.invoice_type or '').strip() != SALE or inv.date is None:
        return None
    until = max(min(as_of, dt.date(inv.date.year, 12, 31)), inv.date.date())
    events = collect_events(year_start(until), dt.datetime.combine(until, dt.time.max))
    price, source = office_prices(until)(until)
    view = sale_view(replay(events), events, invoice_id, price)
    if view is None:
        return None
    numbers = {i.id: (i.invoice_type_id, i.invoice_type) for i in Invoice.query.filter(
        Invoice.id.in_({c['invoice_id'] for c in view['closings'] if c['invoice_id']} or {-1}))}
    for closing in view['closings']:
        closing['invoice_number'], closing['invoice_type'] = numbers.get(closing['invoice_id'], (None, None))
    lot = next((l for l in events.openings if l.invoice_id == invoice_id), None)
    view.update({'as_of': until.isoformat(), 'invoice_number': inv.invoice_type_id,
                 'price_now': round(price, 4), 'price_now_source': source,
                 'closing_price': round(lot.price_at_sale, 4) if lot is not None and lot.price_at_sale else None})
    return view


def performance_by_month(start: dt.date, end: dt.date, events: Events = None, prices=None) -> list:
    """Each month of *start*..*end*: its five layers, from one replay.
    *events* / *prices*: the year's books and purchase prices already read."""
    hi = dt.datetime.combine(end, dt.time.max)
    events = events if events is not None else collect_events(year_start(end), hi)
    prices = prices or office_prices(end)
    result = replay(_until(events, hi))
    rows, previous_u = [], 0.0
    first_month = dt.date(start.year, start.month, 1)
    for m in sorted(result.by_month):
        year, mon = map(int, m.split('-'))
        month_start = dt.date(year, mon, 1)
        month_last = min(dt.date(year + mon // 12, mon % 12 + 1, 1) - dt.timedelta(days=1), end)
        cash_m, grams_m = result.month_end.get(m, (0.0, 0.0))
        price, _ = prices(month_last)
        u = unrealized(cash_m, grams_m, price)
        if month_start >= first_month:
            lo, hi = dt.datetime.combine(month_start, dt.time.min), dt.datetime.combine(month_last, dt.time.max)
            layers = split_layers([s for s in result.slices if lo <= s.when <= hi],
                                  [d for d in result.direct if lo <= d[0] <= hi])
            layers['price_effect'] = u - previous_u
            rows.append({'month': m, 'valuation_price': round(price, 4), 'open_cash': round(cash_m, 2),
                         'unrealized': round(u, 3), 'layers': {k: round(v, 3) for k, v in layers.items()},
                         'weight_profit': round(sum(layers.values()), 3)})
        previous_u = u
    return rows


def performance(start: dt.date, end: dt.date, events: Events = None, prices=None) -> dict:
    """The weight profit of *start*..*end* (inclusive): what was realized in
    it, the weight lines in it, and how the unrealized moved -- from the end
    of the day before *start* (nothing before the year) to the end of *end*."""
    lo, hi = dt.datetime.combine(start, dt.time.min), dt.datetime.combine(end, dt.time.max)
    events = events if events is not None else collect_events(year_start(end), hi)
    prices = prices or office_prices(end)
    result = replay(_until(events, hi))
    taken = [s for s in result.slices if lo <= s.when <= hi]
    by_kind = collections.Counter()
    for piece in taken:
        by_kind[piece.kind] += piece.result
    realized = sum(by_kind.values())
    in_period = [d for d in result.direct if lo <= d[0] <= hi]
    direct = sum(d[1] for d in in_period)
    layers = split_layers(taken, in_period)

    def parts_on(day: dt.date) -> tuple[float, float]:
        if day < year_start(end).date():
            return 0.0, 0.0
        lots = replay(_until(events, dt.datetime.combine(day, dt.time.max))).open_lots
        return unrealized_parts(lots, prices(day)[0])

    sales_before, price_before = parts_on(start - dt.timedelta(days=1))
    sales_after, price_after = parts_on(end)
    before, after = sales_before + price_before, sales_after + price_after
    # ⑤ what waits: how the open riyals' worth in grams moved -- its sales'
    # own profit, and the price's move since (the owner, 2 Nov 2026)
    layers['price_effect'] = after - before
    price, source = prices(end)
    return {
        'start': start.isoformat(), 'end': end.isoformat(),
        'realized': round(realized, 3), 'direct': round(direct, 3),
        'unrealized_start': round(before, 3), 'unrealized_end': round(after, 3),
        'unrealized_change': round(after - before, 3),
        'weight_profit': round(realized + direct + after - before, 3),
        'realized_by_kind': {k: round(v, 3) for k, v in by_kind.items()},
        'layers': {k: round(v, 3) for k, v in layers.items()},
        'price_effect_parts': {'waiting_sales': round(sales_after - sales_before, 3),
                               'price': round(price_after - price_before, 3)},
        'valuation_price': round(price, 4), 'valuation_price_source': source,
    }
