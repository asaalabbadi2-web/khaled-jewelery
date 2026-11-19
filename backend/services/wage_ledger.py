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
    """An invoice's items as wage parts: (karat, category, piece, wage per gram x weight)."""
    from services.pieces import is_piece
    parts = []
    for ii in InvoiceItem.query.filter_by(invoice_id=invoice.id).order_by(InvoiceItem.id).all():
        share = abs(float(ii.wage or 0.0) * float(ii.weight or 0.0))
        if share <= CENT:
            continue
        item = db.session.get(Item, ii.item_id) if ii.item_id else None
        category_id = ii.category_id or getattr(item, 'category_id', None)
        parts.append((int(round(float(ii.karat or 0.0))), category_id,
                      item.id if is_piece(item) else None, share))
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
