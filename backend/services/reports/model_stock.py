"""The pieces that sit, and what to ask the supplier for (ADR-093; the owner, 18 Nov 2026).

Two questions of the stock on a day, from the books alone -- the same reading
as the models' movement (model_movement._entries: a piece's allocations
entry by entry, a transfer no move):
  - slow_pieces: each piece in the stock that day and how long it has sat --
    from the last time it came into the stock (received, or come back);
    those past the days asked, by piece or by model;
  - model_reorder: each model and size -- the sizes the model names, those
    held, those sold -- its pieces in the stock that day, those sold in the
    days before (less those come back), and how many days its stock lasts at
    that pace: run out (none, and named or sold), short (lasts less than the
    days read), or enough. The pace and the days are the report's choice --
    no number of the shop's is written here.
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Column, Report
from services.reports.model_movement import GRAM, NO_MODEL, NO_SIZE, _entries, _walk

SLOW_BY = ('piece', 'model')
RUN_OUT, SHORT, ENOUGH = 'نفد', 'قليل', 'يكفي'


def _end_of(day: dt.date) -> dt.datetime:
    return dt.datetime.combine(day + dt.timedelta(days=1), dt.time.min)


def _entered(events, hi: dt.datetime):
    """When the piece last came into the stock before *hi* -- None if not held then."""
    held, entered = 0.0, None
    for when, _, grams, _ in events:
        if when >= hi:
            break
        was = held > GRAM
        held += grams
        if held > GRAM and not was:
            entered = when
    return entered if held > GRAM else None


def _names(pieces):
    from models import PieceModel, SafeBox, SizeSystemSize
    models = {m.id: m.name for m in PieceModel.query.filter(
        PieceModel.id.in_({p.model_id for p in pieces if p.model_id} or {-1}))}
    sizes = {z.id: (z.label, z.position) for z in SizeSystemSize.query.filter(
        SizeSystemSize.id.in_({p.size_id for p in pieces if p.size_id} or {-1}))}
    return models, sizes


def slow_pieces(*, now: dt.datetime, as_of: dt.date, min_days: int = 90, by: str = 'piece',
                category_id=None) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from models import Category, Item
    if by not in SLOW_BY:
        raise ValueError(f'by is {"|".join(SLOW_BY)}, not {by!r}')
    if int(min_days) < 0:
        raise ValueError('min_days is a number of days, 0 or more')
    hi = _end_of(as_of)
    events = _entries(category_id)
    pieces = {p.id: p for p in Item.query.filter(Item.id.in_(list(events) or [-1]))}
    models, sizes = _names(pieces.values())
    categories = {c.id: c.name for c in Category.query.filter(
        Category.id.in_({p.category_id for p in pieces.values()} or {-1}))}
    sitting = []
    for piece_id, piece_events in events.items():
        piece = pieces.get(piece_id)
        entered = _entered(piece_events, hi) if piece else None
        if entered is None:
            continue
        days = (as_of - entered.date()).days
        if days >= int(min_days):
            sitting.append((piece, entered, days))
    sitting.sort(key=lambda s: (-s[2], s[0].item_code or ''))

    if by == 'piece':
        rows = [{'item_code': p.item_code, 'model': models.get(p.model_id, NO_MODEL),
                 'size': sizes[p.size_id][0] if p.size_id in sizes else NO_SIZE,
                 'category': categories.get(p.category_id), 'weight': round(float(p.weight or 0.0), 3),
                 'entered': entered.date().isoformat(), 'days': days} for p, entered, days in sitting]
        columns = [Column('item_code', 'رقم القطعة'), Column('model', 'الموديل'), Column('size', 'المقاس'),
                   Column('category', 'التصنيف'), Column('weight', 'الوزن', 'grams'),
                   Column('entered', 'دخلت المخزون', 'date'), Column('days', 'الأيام', 'count')]
    else:
        groups = collections.OrderedDict()
        for p, entered, days in sitting:
            g = groups.setdefault(p.model_id, {'model': models.get(p.model_id, NO_MODEL), 'pieces': 0,
                                               'weight': 0.0, 'days': []})
            g['pieces'] += 1
            g['weight'] += float(p.weight or 0.0)
            g['days'].append(days)
        rows = [{'model': g['model'], 'pieces': g['pieces'], 'weight': round(g['weight'], 3),
                 'oldest': max(g['days']), 'average': round(sum(g['days']) / len(g['days']))}
                for g in sorted(groups.values(), key=lambda g: -max(g['days']))]
        columns = [Column('model', 'الموديل'), Column('pieces', 'القطع', 'count'),
                   Column('weight', 'الوزن', 'grams'), Column('oldest', 'أقدمها (يوم)', 'count'),
                   Column('average', 'متوسط الأيام', 'count')]
    weight = round(sum(float(p.weight or 0.0) for p, _, _ in sitting), 3)
    totals = {'pieces': len(sitting), 'weight': weight} if by == 'model' else {'weight': weight}
    return Report(id='slow_pieces', title='القطع الراكدة', basis='posted_entries', columns=columns, rows=rows,
                  totals=totals, checks=[], start=None, end=as_of, read_at=now)


def model_reorder(*, now: dt.datetime, as_of: dt.date, days: int = 30, category_id=None) -> Report:
    """*days*: the pace read -- the sales of the days before *as_of*, and the
    span the stock is to last. *now*: the caller's clock (ADR-015)."""
    from models import Item, PieceModel, PieceModelSize, SizeSystemSize
    days = int(days)
    if days < 1:
        raise ValueError('days is a number of days, 1 or more')
    hi = _end_of(as_of)
    lo = hi - dt.timedelta(days=days)
    events = _entries(category_id)
    pieces = {p.id: p for p in Item.query.filter(Item.id.in_(list(events) or [-1]))}

    held = collections.Counter()
    sold = collections.Counter()
    for piece_id, piece_events in events.items():
        piece = pieces.get(piece_id)
        if piece is None or piece.model_id is None:
            continue                                   # a reorder is a model's: the loose pieces have none
        key = (piece.model_id, piece.size_id)
        if _entered(piece_events, hi) is not None:
            held[key] += 1
        walk = _walk(piece_events, lo, hi)
        sold[key] += walk['moves']['sold'] - walk['moves']['came_back']

    model_query = PieceModel.query.filter(PieceModel.is_active.is_(True))
    if category_id is not None:
        model_query = model_query.filter(PieceModel.category_id == int(category_id))
    active = {m.id: m for m in model_query}
    keys = set(held) | {k for k, n in sold.items() if n} | {
        (r.model_id, r.size_id) for r in PieceModelSize.query.filter(PieceModelSize.model_id.in_(list(active) or [-1]))}
    names = {m.id: m.name for m in PieceModel.query.filter(PieceModel.id.in_({k[0] for k in keys} or {-1}))}
    sizes = {z.id: (z.label, z.position) for z in SizeSystemSize.query.filter(
        SizeSystemSize.id.in_({k[1] for k in keys if k[1]} or {-1}))}

    rows = []
    for model_id, size_id in sorted(keys, key=lambda k: (names.get(k[0], ''),
                                                         sizes.get(k[1], ('', 10**6))[1])):
        in_stock, out = held[(model_id, size_id)], max(sold[(model_id, size_id)], 0)
        cover = round(in_stock / out * days) if out else None
        state = RUN_OUT if in_stock == 0 else SHORT if (cover is not None and cover < days) else ENOUGH
        rows.append({'model': names.get(model_id, NO_MODEL),
                     'size': sizes[size_id][0] if size_id in sizes else NO_SIZE,
                     'in_stock': in_stock, 'sold': out, 'cover': cover, 'state': state})
    rows.sort(key=lambda r: ({RUN_OUT: 0, SHORT: 1, ENOUGH: 2}[r['state']], r['model']))
    totals = {'in_stock': sum(r['in_stock'] for r in rows), 'sold': sum(r['sold'] for r in rows)}
    columns = [Column('state', 'الحال'), Column('model', 'الموديل'), Column('size', 'المقاس'),
               Column('in_stock', 'في المخزون', 'count'), Column('sold', f'بيع في {days} يومًا', 'count'),
               Column('cover', 'يكفي (يومًا)', 'count')]
    return Report(id='model_reorder', title='ما يُطلب من المورد', basis='posted_entries', columns=columns,
                  rows=rows, totals=totals, checks=[], start=as_of - dt.timedelta(days=days - 1), end=as_of,
                  read_at=now)
