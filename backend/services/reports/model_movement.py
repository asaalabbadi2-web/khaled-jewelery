"""The models' movement in a period (ADR-093; the owner, 18 Nov 2026).

«هل ستتبع التقارير حركة الموديل؟» -- each model (and size): what was in the
stock when the period began, what came in, what went out by which document,
and what is left -- in pieces, and the grams left. From the books alone: a
piece's allocations on counted lines (ADR-045), read entry by entry -- an
entry moving it between two safes nets to nothing and is no movement. A
piece that comes into the stock for the first time is received; one that
comes back (a sale returned) came back; one that leaves is sold (a sale),
returned to its supplier, or out (any other document). So what was, plus
what came in, less what went out, is what is left -- and the report checks
it, and that what is left at the end is the pieces its stock holds.
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Check, Column, Report

GRAM = 0.0005
BY = ('model', 'model_size')
SALE, SUPPLIER_RETURN = 'بيع', 'مرتجع شراء (مورد)'
NO_MODEL, NO_SIZE = 'بلا موديل', 'بلا مقاس'
MOVES = ('received', 'came_back', 'sold', 'returned', 'out')


def _entries(category_id=None) -> dict:
    """{piece id: [(date, entry id, grams, document kind)]} -- a piece's net grams
    by entry, in their order; the document's kind for an entry of an invoice."""
    from accounting.balances import counted_line_filters
    from models import Invoice, Item, JournalEntry, JournalEntryLine, StockLineAllocation, db
    query = (db.session.query(StockLineAllocation.item_id, JournalEntry.id, JournalEntry.date,
                              JournalEntry.reference_type, JournalEntry.reference_id,
                              db.func.sum(StockLineAllocation.grams))
             .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(StockLineAllocation.item_id.isnot(None), *counted_line_filters()))
    if category_id is not None:
        query = query.join(Item, Item.id == StockLineAllocation.item_id).filter(Item.category_id == int(category_id))
    rows = query.group_by(StockLineAllocation.item_id, JournalEntry.id, JournalEntry.date,
                          JournalEntry.reference_type, JournalEntry.reference_id).all()
    invoices = {i for _, _, _, kind, i, _ in rows if kind == 'invoice' and i}
    kinds = {inv.id: (inv.invoice_type or '').strip()
             for inv in Invoice.query.filter(Invoice.id.in_(invoices or {-1}))}
    out = collections.defaultdict(list)
    for item_id, entry_id, date, ref_type, ref_id, grams in rows:
        if abs(float(grams or 0.0)) > GRAM:
            out[item_id].append((date, entry_id, float(grams), kinds.get(ref_id) if ref_type == 'invoice' else None))
    for events in out.values():
        events.sort(key=lambda e: (e[0], e[1]))
    return out


def _walk(events, lo: dt.datetime, hi: dt.datetime) -> dict:
    """A piece's period: held at its start and end, and each move in it."""
    held = sum(g for when, _, g, _ in events if when < lo)
    opening = held > GRAM
    moves = collections.Counter()
    ever = any(when < lo for when, *_ in events)
    state = opening
    for when, _, grams, kind in events:
        if not (lo <= when < hi):
            continue
        held += grams
        now_in = held > GRAM
        if now_in and not state:
            moves['came_back' if ever else 'received'] += 1
        elif state and not now_in:
            moves['sold' if kind == SALE else 'returned' if kind == SUPPLIER_RETURN else 'out'] += 1
        ever = True
        state = now_in
    return {'opening': opening, 'closing': state, 'moves': moves}


def model_movement(*, now: dt.datetime, start: dt.date, end: dt.date, category_id=None,
                   by: str = 'model_size') -> Report:
    """*now*: the caller's clock (ADR-015). *by*: 'model' or 'model_size'."""
    from models import Item, PieceModel, SizeSystemSize
    if by not in BY:
        raise ValueError(f'by is {"|".join(BY)}, not {by!r}')
    lo = dt.datetime.combine(start, dt.time.min)
    hi = dt.datetime.combine(end + dt.timedelta(days=1), dt.time.min)
    events = _entries(category_id)
    pieces = {p.id: p for p in Item.query.filter(Item.id.in_(list(events) or [-1]))}
    models = {m.id: m.name for m in PieceModel.query.filter(
        PieceModel.id.in_({p.model_id for p in pieces.values() if p.model_id} or {-1}))}
    sizes = {z.id: (z.label, z.position) for z in SizeSystemSize.query.filter(
        SizeSystemSize.id.in_({p.size_id for p in pieces.values() if p.size_id} or {-1}))}

    groups = collections.OrderedDict()
    for piece_id, piece_events in events.items():
        piece = pieces.get(piece_id)
        if piece is None:
            continue
        walk = _walk(piece_events, lo, hi)
        if not (walk['opening'] or walk['closing'] or walk['moves']):
            continue
        size_id = piece.size_id if by == 'model_size' else None
        key = (piece.model_id, size_id)
        g = groups.setdefault(key, {'model': models.get(piece.model_id, NO_MODEL),
                                    'size': sizes[size_id][0] if size_id in sizes else NO_SIZE,
                                    'position': sizes[size_id][1] if size_id in sizes else 10**6,
                                    'opening': 0, 'closing': 0, 'closing_weight': 0.0,
                                    **{m: 0 for m in MOVES}})
        g['opening'] += walk['opening']
        g['closing'] += walk['closing']
        g['closing_weight'] += float(piece.weight or 0.0) if walk['closing'] else 0.0
        for move, n in walk['moves'].items():
            g[move] += n

    rows = []
    for (model_id, size_id), g in sorted(groups.items(), key=lambda kv: (kv[1]['model'] == NO_MODEL,
                                                                          kv[1]['model'], kv[1]['position'])):
        row = {'model': g['model'], 'opening': g['opening'], **{m: g[m] for m in MOVES},
               'closing': g['closing'], 'closing_weight': round(g['closing_weight'], 3)}
        if by == 'model_size':
            row['size'] = g['size']
        rows.append(row)

    def total(key):
        return sum(r[key] for r in rows)
    totals = {k: total(k) for k in ('opening', *MOVES, 'closing')}
    totals['closing_weight'] = round(total('closing_weight'), 3)
    balanced = all(r['opening'] + r['received'] + r['came_back'] - r['sold'] - r['returned'] - r['out']
                   == r['closing'] for r in rows)
    checks = [Check('balance', 'أول الفترة + ما دخل − ما خرج = آخر الفترة', balanced)]
    if end >= now.date():
        from services.pieces import stock_pieces
        held = sum(1 for p, _ in stock_pieces(category_id))
        checks.append(Check('stock_agrees', 'آخر الفترة يساوي القطع في المخزون الآن', totals['closing'] == held))

    columns = [Column('model', 'الموديل')]
    if by == 'model_size':
        columns.append(Column('size', 'المقاس'))
    columns += [Column('opening', 'أول الفترة', 'count'), Column('received', 'استُلم', 'count'),
                Column('came_back', 'عاد', 'count'), Column('sold', 'بيع', 'count'),
                Column('returned', 'أُرجع للمورد', 'count'), Column('out', 'خرج', 'count'),
                Column('closing', 'آخر الفترة', 'count'), Column('closing_weight', 'وزنه', 'grams')]
    return Report(id='model_movement', title='حركة الموديلات', basis='posted_entries', columns=columns, rows=rows,
                  totals=totals, checks=checks, start=start, end=end, read_at=now)
