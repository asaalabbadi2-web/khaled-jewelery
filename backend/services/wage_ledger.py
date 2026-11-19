"""The wages' stock by category and piece: the lines on 1320 themselves (ADR-096 ت1).

A wage is the goods' own cost (ADR-096). The wages' stock is the posted lines
on 1320 «مخزون أجور المصنعية»; each is allocated (WageAllocation) to the pool
of a category -- or of a karat's «بلا تصنيف» -- or to a piece's own wage. A
pool is its riyals here and its grams in the stock (the gold's allocations,
ADR-045): one reading each, no second ledger to drift.

From Settings.wage_pools_from on (the owner, 19 Nov 2026: 2027's opening):
- allocate(): the one writer, and its law -- a line's allocations carry its
  sign and add up to no more than it;
- allocate_invoice_wages(): an invoice's lines on 1320 laid on its items by
  each one's wage (its wage per gram x its weight), the halala's rounding on
  the last; a line with no item carrying a wage is refused, and so the posting;
- wage_allocation_guard refuses a commit leaving a line on 1320 not allocated
  whole -- a hand's entry on 1320 is not written (the owner, 19 Nov 2026);
- pools(): the one reader of the pools.
Before that day, nothing here is written or refused: 2026's books stay as
they are until the 31 Dec tool (ت5).
"""
from __future__ import annotations

from datetime import date, datetime

from sqlalchemy import func

from models import Invoice, InvoiceItem, Item, JournalEntry, JournalEntryLine, WageAllocation, db

CENT = 0.005
GRAM = 0.0005


class WageAllocationError(ValueError):
    """An allocation the law refuses -- the posting that asked for it is refused with it."""
    code = 'wage_not_allocated'

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


# ── from which day ───────────────────────────────────────────────────────────

def wage_pools_from():
    from models import Settings
    return getattr(Settings.query.first(), 'wage_pools_from', None)


def wage_pools_on(day) -> bool:
    """Whether a line dated *day* on 1320 is allocated, and refused when not."""
    start = wage_pools_from()
    if start is None or day is None:
        return False
    if isinstance(day, datetime):
        day = day.date()
    return isinstance(day, date) and day >= start


def wage_account_id():
    """1320 -- the mapped role, nothing else (CHART-002)."""
    from accounting.wages import manufacturing_wage_inventory_account_id
    return manufacturing_wage_inventory_account_id()


# ── the writer ───────────────────────────────────────────────────────────────

def line_riyals(line) -> float:
    return round(float(line.cash_debit or 0.0) - float(line.cash_credit or 0.0), 2)


def allocated(line_id: int) -> float:
    return round(float(db.session.query(func.coalesce(func.sum(WageAllocation.riyals), 0.0))
                       .filter(WageAllocation.journal_entry_line_id == int(line_id)).scalar() or 0.0), 2)


def allocate(line, *, karat: int, category_id, riyals: float, item_id=None, now, by=None) -> WageAllocation:
    """Riyals of a line on 1320 to a category's pool (none: the karat's «بلا
    تصنيف») or to a piece -- or WageAllocationError."""
    if int(line.account_id) != (wage_account_id() or -1):
        raise WageAllocationError(f'السطر {line.id} ليس على مخزون أجور المصنعية')
    net = line_riyals(line)
    riyals = round(float(riyals), 2)
    if riyals * net < 0:
        raise WageAllocationError(f'التوزيع بعكس إشارة السطر {line.id}')
    if abs(allocated(line.id) + riyals) > abs(net) + CENT:
        raise WageAllocationError(f'التوزيع يتجاوز السطر {line.id}: {abs(allocated(line.id) + riyals):.2f} '
                                  f'من {abs(net):.2f}')
    row = WageAllocation(journal_entry_line_id=line.id, karat=int(karat),
                         category_id=int(category_id) if category_id else None,
                         item_id=int(item_id) if item_id else None, riyals=riyals, created_at=now, created_by=by)
    db.session.add(row)
    db.session.flush()
    return row


def spread(line, parts, *, now, by=None, what: str) -> list:
    """A line on 1320 laid on parts -- (karat, category_id, item_id, share),
    share above zero -- each its share of the line, the halala's rounding on
    the last: the line allocated whole. No part: refused."""
    parts = [p for p in parts if p[3] > CENT]
    net = line_riyals(line)
    if abs(net) <= CENT:
        return []
    if not parts:
        raise WageAllocationError(f'{what}: على مخزون أجور المصنعية {abs(net):,.2f} ولا صنف فيها بأجرة '
                                  'يُوزَّع عليه')
    total = sum(p[3] for p in parts)
    written, left = [], net
    for n, (karat, category_id, item_id, share) in enumerate(parts):
        riyals = left if n == len(parts) - 1 else round(net * share / total, 2)
        left = round(left - riyals, 2)
        if abs(riyals) > CENT:
            written.append(allocate(line, karat=karat, category_id=category_id, riyals=riyals, item_id=item_id,
                                    now=now, by=by))
    return written


def spread_net(line, parts, *, now, by=None, what: str) -> list:
    """A line on 1320 that nets movements of several pools -- a correction's:
    the old line's wage back into its category, the right line's out of
    its own -- laid on parts (karat, category_id, item_id, riyals signed),
    each its share of the line in its own sign, the halala's rounding on the
    last: the line allocated whole. A line not netting its parts' sum is laid
    in proportion (its VAT, when the wages' VAT is not recovered). Parts
    netting nothing for a line that moves: refused."""
    parts = [p for p in parts if abs(p[3]) > CENT]
    net = line_riyals(line)
    if abs(net) <= CENT:
        return []
    total = round(sum(p[3] for p in parts), 2)
    if abs(total) <= CENT:
        raise WageAllocationError(f'{what}: على مخزون أجور المصنعية {net:,.2f} وأجزاؤها لا تجمع شيئًا')
    if abs(allocated(line.id)) > CENT:
        raise WageAllocationError(f'السطر {line.id} موزَّع من قبل')
    written, left = [], net
    for n, (karat, category_id, item_id, riyals) in enumerate(parts):
        share = left if n == len(parts) - 1 else round(riyals * net / total, 2)
        left = round(left - share, 2)
        if abs(share) > CENT:
            row = WageAllocation(journal_entry_line_id=line.id, karat=int(karat),
                                 category_id=int(category_id) if category_id else None,
                                 item_id=int(item_id) if item_id else None, riyals=share, created_at=now,
                                 created_by=by)
            db.session.add(row)
            written.append(row)
    db.session.flush()
    return written


def allocate_entry_wages(entry, parts, *, now, by=None, what: str, net: bool = False) -> list:
    """An entry's lines on 1320 not yet allocated, laid on *parts* -- from
    wage_pools_from on; a failure refuses the entry. `net`: the parts carry
    their own signs (spread_net); else shares of the line (spread)."""
    if entry is None or not wage_pools_on(entry.date):
        return []
    account = wage_account_id()
    if not account:
        return []
    lines = [l for l in JournalEntryLine.query.filter_by(journal_entry_id=entry.id, account_id=account,
                                                         is_deleted=False).order_by(JournalEntryLine.id)
             if abs(allocated(l.id)) <= CENT]
    written = []
    try:
        for line in lines:
            written += (spread_net if net else spread)(line, parts, now=now, by=by, what=what)
    except WageAllocationError as refused:
        from wage_allocation_guard import _mark_the_request
        _mark_the_request(refused)
        raise
    return written


def mirror_wage_allocations(pairs, *, now, by=None) -> list:
    """A reversal's lines on 1320 take back the pools of the lines they reverse
    -- (original, reversal) pairs -- as the gold's categories go back with them
    (services/stock_ledger.mirror_allocations)."""
    written = []
    for original, reversal in pairs:
        for a in WageAllocation.query.filter_by(journal_entry_line_id=original.id).order_by(WageAllocation.id):
            written.append(allocate(reversal, karat=a.karat, category_id=a.category_id, riyals=-float(a.riyals),
                                    item_id=a.item_id, now=now, by=by))
    return written


def invoice_wage_parts(invoice: Invoice) -> list:
    """An invoice's items as wage parts: (karat, category, piece, wage per gram x weight).
    A receipt's line with pieces coded under it before its invoice was
    completed: each piece its share, the rest its category's (ADR-096 ت3)."""
    from services.pieces import is_piece, line_pieces
    parts = []
    for ii in InvoiceItem.query.filter_by(invoice_id=invoice.id).order_by(InvoiceItem.id).all():
        share = abs(float(ii.wage or 0.0) * float(ii.weight or 0.0))
        if share <= CENT:
            continue
        item = db.session.get(Item, ii.item_id) if ii.item_id else None
        category_id = ii.category_id or getattr(item, 'category_id', None)
        karat = int(round(float(ii.karat or 0.0)))
        if item is None and line_pieces(ii):
            parts += [p for p in receipt_line_parts(ii, karat=karat, category_id=category_id,
                                                    per_gram=abs(float(ii.wage or 0.0)),
                                                    weight=float(ii.weight or 0.0)) if p[3] > CENT]
            continue
        parts.append((karat, category_id, item.id if is_piece(item) else None, share))
    return parts


def _invoice_wage_lines(invoice: Invoice) -> list:
    account = wage_account_id()
    if not account:
        return []
    return (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice.id,
                    JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False),
                    JournalEntryLine.account_id == account)
            .order_by(JournalEntryLine.id).all())


def allocate_invoice_wages(invoice: Invoice, *, now, by=None) -> list:
    """An invoice's lines on 1320 laid on its items, in its posting's
    transaction -- from wage_pools_from on; a failure refuses the posting.
    Idempotent: a line already allocated is left as it is."""
    if not wage_pools_on(invoice.date):
        return []
    lines = [l for l in _invoice_wage_lines(invoice) if abs(allocated(l.id)) <= CENT]
    if not lines:
        return []
    parts = invoice_wage_parts(invoice)
    written = []
    try:
        for line in lines:
            written += spread(line, parts, now=now, by=by,
                              what=f'الفاتورة {invoice.invoice_number or invoice.id}')
    except WageAllocationError as refused:
        from wage_allocation_guard import _mark_the_request
        _mark_the_request(refused)          # the route's broad except answers it readably
        raise
    return written


# ── the reader ───────────────────────────────────────────────────────────────

def _counted(query):
    from accounting.balances import counted_line_filters
    return (query.join(JournalEntryLine, JournalEntryLine.id == WageAllocation.journal_entry_line_id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters()))


def pools() -> dict:
    """{(karat, category_id or None): {'riyals', 'grams'}} -- each pool's
    wages (no piece's) on posted lines, and its grams in the stock under no
    piece (an office's deposit is not ours to sell, ADR-052)."""
    from accounting.balances import counted_line_filters
    from models import SafeBox, StockLineAllocation
    from services.stock_ledger import stock_balances
    out: dict = {}
    for karat, category_id, riyals in _counted(
            db.session.query(WageAllocation.karat, WageAllocation.category_id, func.sum(WageAllocation.riyals))
            .filter(WageAllocation.item_id.is_(None))).group_by(WageAllocation.karat,
                                                                WageAllocation.category_id).all():
        out.setdefault((int(karat), category_id), {'riyals': 0.0, 'grams': 0.0})['riyals'] = round(float(riyals), 2)
    selling = {b.account_id for b in SafeBox.query.filter(SafeBox.stock_location.isnot(None),
                                                         SafeBox.stock_location != 'deposit')}
    selling_ids = {b.id for b in SafeBox.query.filter(SafeBox.account_id.in_(list(selling) or [-1]))}
    for karat, category_id, grams in (
            db.session.query(StockLineAllocation.karat, StockLineAllocation.category_id,
                             func.sum(StockLineAllocation.grams))
            .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(StockLineAllocation.item_id.is_(None), JournalEntryLine.account_id.in_(list(selling) or [-1]),
                    *counted_line_filters())
            .group_by(StockLineAllocation.karat, StockLineAllocation.category_id).all()):
        out.setdefault((int(karat), category_id), {'riyals': 0.0, 'grams': 0.0})['grams'] = round(float(grams), 3)
    for row in stock_balances():
        if row['category_id'] is None and row['safe_box_id'] in selling_ids:
            pool = out.setdefault((int(row['karat']), None), {'riyals': 0.0, 'grams': 0.0})
            pool['grams'] = round(pool['grams'] + float(row['grams']), 3)
    return out


def pool_average(karat: int, category_id) -> dict:
    """A pool's wage a gram now -- its riyals over its grams; None when it has
    no grams or no riyals. What the sale screen shows as the line's cost."""
    pool = pools().get((int(karat), category_id), {'riyals': 0.0, 'grams': 0.0})
    per_gram = (round(pool['riyals'] / pool['grams'], 6)
                if pool['riyals'] > CENT and pool['grams'] > GRAM else None)
    return {**pool, 'per_gram': per_gram}


def riyals_at_average(pool: dict, grams: float) -> float:
    """What *grams* take out of *pool* at its average -- what it holds and no
    more, never below zero (the owner, 19 Nov 2026): the one rule of a pool's
    wage leaving it, for a sale, a coding, a melting, a count."""
    if grams <= GRAM or pool['riyals'] <= CENT:
        return 0.0
    if pool['grams'] >= grams - GRAM:
        return min(round(pool['riyals'] * grams / pool['grams'], 2), round(pool['riyals'], 2))
    return round(pool['riyals'], 2)                     # what it holds, no more


def take_out(held: dict, key, grams: float) -> float:
    """riyals_at_average from *held*'s pool *key*, the pool left as it is after."""
    pool = held.setdefault(key, {'riyals': 0.0, 'grams': 0.0})
    riyals = riyals_at_average(pool, grams)
    pool['riyals'], pool['grams'] = round(pool['riyals'] - riyals, 2), round(pool['grams'] - grams, 3)
    return riyals


def sale_wage_costs(invoice: Invoice) -> dict:
    """{invoice line id: its wage's cost in riyals} for a sale, from
    wage_pools_from on (ADR-096 ت2): a piece its own wage; a weighed line its
    pool's average times its grams, the lines of one pool in an invoice taken
    together, the halala on the last. A pool holding fewer grams than sold
    gives what it holds and no more -- never below zero (the owner, 19 Nov
    2026); WAGE_POOL_OVERSOLD says so at night."""
    from services.pieces import is_piece, piece_wage
    held = pools()
    costs, wanted = {}, {}
    for ii in InvoiceItem.query.filter_by(invoice_id=invoice.id).order_by(InvoiceItem.id).all():
        grams = float(ii.weight or 0.0)
        if grams <= GRAM:
            continue
        item = db.session.get(Item, ii.item_id) if ii.item_id else None
        if is_piece(item):
            costs[ii.id] = round(float(piece_wage(item) or 0.0), 2)
            continue
        key = (int(round(float(ii.karat or 0.0))), ii.category_id or getattr(item, 'category_id', None))
        wanted.setdefault(key, []).append((ii.id, grams))
    for key, rows in wanted.items():
        sold = sum(g for _, g in rows)
        total = take_out(held, key, sold)
        left = total
        for n, (line_id, grams) in enumerate(rows):
            share = left if n == len(rows) - 1 else round(total * grams / sold, 2)
            left = round(left - share, 2)
            costs[line_id] = share
    return costs


# ── a pool's wage moving (ADR-096 ت3) ───────────────────────────────────────

def move_to_piece(karat: int, category_id, piece_id: int, riyals: float, *, lines=None, now, by=None) -> list:
    """*riyals* of a pool's wage become a piece's own: its rows (on *lines*
    only, when given -- a receipt's piece takes its invoice's) split, each
    line's allocations unchanged in sum. A coding writes no entry: the
    riyals stay on 1320, only whose they are changes -- as its grams do
    (services/pieces.register_piece). Not enough in the pool: refused."""
    riyals = round(float(riyals or 0.0), 2)
    if riyals <= CENT:
        return []
    query = _counted(WageAllocation.query.filter(
        WageAllocation.item_id.is_(None), WageAllocation.karat == int(karat), WageAllocation.riyals > CENT,
        WageAllocation.category_id == int(category_id) if category_id else WageAllocation.category_id.is_(None)))
    if lines is not None:
        query = query.filter(WageAllocation.journal_entry_line_id.in_([int(l) for l in lines] or [-1]))
    written, left = [], riyals
    for row in query.order_by(WageAllocation.id).all():
        if left <= CENT:
            break
        take = round(min(left, float(row.riyals)), 2)
        row.riyals = round(float(row.riyals) - take, 2)
        if row.riyals <= CENT:
            db.session.delete(row)
        piece_row = WageAllocation(journal_entry_line_id=row.journal_entry_line_id, karat=int(karat),
                                   category_id=int(category_id) if category_id else None, item_id=int(piece_id),
                                   riyals=take, created_at=now, created_by=by)
        db.session.add(piece_row)
        written.append(piece_row)
        left = round(left - take, 2)
    if left > CENT:
        raise WageAllocationError(f'وعاء الأجور لا يحمل أجرة القطعة: ينقصه {left:,.2f}')
    db.session.flush()
    return written


def receipt_line_parts(line, *, karat: int, category_id, per_gram: float, weight: float, sign: int = 1) -> list:
    """A receipt line's wage as parts: each piece under it its share (law 5),
    the rest its category's -- signed. The wage of a piece coded from the
    line is its own, in the ledger as in its share."""
    from services.pieces import line_pieces, wage_shares
    shares, rest = wage_shares(line_pieces(line), float(per_gram or 0.0), float(weight or 0.0))
    parts = [(int(karat), category_id, piece_id, sign * share) for piece_id, share in shares.items()]
    if abs(rest) > CENT:
        parts.append((int(karat), category_id, None, sign * rest))
    return parts


def melting_wage(parts) -> tuple:
    """(riyals, [(karat, category_id, None, riyals)]): the wage a melting of
    *parts* -- (karat, category_id, grams) -- writes off, each pool at its
    average (ADR-096 §2), not a wage written by hand."""
    held, out = pools(), {}
    for karat, category_id, grams in parts:
        key = (int(karat), category_id or None)
        out[key] = round(out.get(key, 0.0) + take_out(held, key, float(grams or 0.0)), 2)
    rows = [(k[0], k[1], None, r) for k, r in out.items() if r > CENT]
    return round(sum(r for *_, r in rows), 2), rows


def value_the_count_wages(entry, groups, held, *, shortage_account_id, surplus_account_id, now, by=None) -> list:
    """A count's wages (ADR-096 §2), from wage_pools_from on: per safe and
    karat, what moved from one category to another at the leaving one's
    average; what was found short at its average onto the shortage, what was
    found over at its category's average from the surplus (the owner, 19 Nov
    2026). *groups*: {(safe, karat): [(category_id, grams)]} -- the count's own;
    *held*: the pools before it. Lines on 1320 allocated to their pools, each
    side its sign."""
    if not wage_pools_on(entry.date):
        return []
    account = wage_account_id()
    if not account:
        return []
    from dimensions_service import compute_line_analytics
    out_parts, in_parts, lost, gained = [], [], 0.0, 0.0
    for (_safe, karat), parts in sorted(groups.items(), key=lambda g: (g[0][0], g[0][1])):
        short = [(c, -g) for c, g in parts if g < -GRAM]
        over = [(c, g) for c, g in parts if g > GRAM]
        missing, found = sum(g for _, g in short), sum(g for _, g in over)
        taken = [(c, take_out(held, (int(karat), c or None), g)) for c, g in short]
        out_riyals = round(sum(r for _, r in taken), 2)
        out_parts += [(int(karat), c, None, -r) for c, r in taken if r > CENT]
        moved_share = min(1.0, found / missing) if missing > GRAM else 0.0
        moved = round(out_riyals * moved_share, 2)
        lost = round(lost + out_riyals - moved, 2)
        moved_grams, left_moved = min(found, missing), moved
        for n, (c, g) in enumerate(over):
            key = (int(karat), c or None)
            pool = held.setdefault(key, {'riyals': 0.0, 'grams': 0.0})
            from_moved = left_moved if n == len(over) - 1 else round(moved * g / found, 2)
            left_moved = round(left_moved - from_moved, 2)
            extra = g - g * moved_grams / found                            # found over the moved: a surplus
            from_surplus = round(pool['riyals'] * extra / pool['grams'], 2) \
                if pool['riyals'] > CENT and pool['grams'] > GRAM else 0.0
            pool['riyals'] = round(pool['riyals'] + from_moved + from_surplus, 2)
            pool['grams'] = round(pool['grams'] + g, 3)
            gained = round(gained + from_surplus, 2)
            if from_moved + from_surplus > CENT:
                in_parts.append((int(karat), c, None, round(from_moved + from_surplus, 2)))
    written = []

    def line(account_id, riyals, what):
        row = JournalEntryLine(journal_entry_id=entry.id, account_id=account_id, description=what[:200],
                               **({'cash_debit': riyals} if riyals > 0 else {'cash_credit': -riyals}))
        row.analytic_amount_cash, row.analytic_weight_24k, row.analytic_weight_main = \
            compute_line_analytics(db.session, row)
        db.session.add(row)
        db.session.flush()
        return row

    what = (entry.description or 'فروق جرد')[:150]
    for parts, sign, label in ((out_parts, -1, 'أجور خرجت من تصنيفاتها'), (in_parts, 1, 'أجور دخلت تصنيفاتها')):
        total = round(sum(p[3] for p in parts), 2)
        if abs(total) > CENT:
            written += spread_net(line(account, total, f'{what} — {label}'), parts, now=now, by=by, what=what)
    if lost > CENT:
        line(shortage_account_id, lost, f'{what} — أجور الناقص')
    if gained > CENT:
        line(surplus_account_id, -gained, f'{what} — أجور الزائد')
    return written


def unallocated_lines(*, since=None) -> list:
    """Lines on 1320 from wage_pools_from (or *since*) whose allocations are
    not the line: [(line, its riyals, allocated)]."""
    from accounting.balances import counted_line_filters
    start = since or wage_pools_from()
    account = wage_account_id()
    if start is None or not account:
        return []
    sums = (db.session.query(WageAllocation.journal_entry_line_id, func.sum(WageAllocation.riyals).label('a'))
            .group_by(WageAllocation.journal_entry_line_id).subquery())
    rows = (db.session.query(JournalEntryLine, func.coalesce(sums.c.a, 0.0))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .outerjoin(sums, sums.c.journal_entry_line_id == JournalEntryLine.id)
            .filter(JournalEntryLine.account_id == account, JournalEntry.date >= datetime.combine(start, datetime.min.time()),
                    *counted_line_filters()).all())
    return [(line, line_riyals(line), round(float(a), 2)) for line, a in rows
            if abs(line_riyals(line) - round(float(a), 2)) > CENT]
