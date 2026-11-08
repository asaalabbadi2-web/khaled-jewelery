"""The purchase lots made items give their item back to their category (the owner, 8 Nov 2026).

Until 5303e152 the purchase screen made each typed line an item in the
catalogue (create_inline): on the 5 Nov copy 18 lots, «I-» numbered, in the
table that holds the piece (ADR-085) -- I-000001 «سلاسل حبل ومبروم» 139 g,
I-000002 of 0 g -- two of them on the stock: I-000017 «اطقم سلم» 33 g and
I-000019 «بناجر 12.75» 72.22 g. The transition carries an allocation's item
into 2027 (ADR-044), and a piece's number is «KJ-» (ADR-085).

Each allocation carrying an «I-» item is written again by the one writer
(services/stock_ledger.allocate): the same line, karat, category and grams,
without the item. The category's grams do not move; the books are not
touched; the invoice lines keep naming the item they were saved with. A piece
(any other number) is left. One audit row per allocation. Dry run by default
(nothing changed); a second run finds nothing. Caller commits.
"""
from __future__ import annotations

import json

from models import AuditLog, Item, JournalEntryLine, StockLineAllocation, db

LOT_SERIES = 'I-'


def _audit(by, entity_id, details):
    db.session.add(AuditLog(user_name=by, action='release_lot_item', entity_type='stock_line_allocation',
                            entity_id=entity_id, details=json.dumps(details, ensure_ascii=False, default=str),
                            success=True))


def release_lot_items(*, by: str, now, dry_run: bool = True) -> dict:
    """Every allocation carrying a lot «item», written again without it; what moved, said."""
    from services.stock_ledger import allocate

    rows = (db.session.query(StockLineAllocation, Item)
            .join(Item, Item.id == StockLineAllocation.item_id)
            .filter(Item.item_code.like(f'{LOT_SERIES}%'))
            .order_by(StockLineAllocation.id).all())
    plan = []
    for allocation, item in rows:
        step = {'allocation_id': allocation.id, 'line_id': allocation.journal_entry_line_id,
                'item_code': item.item_code, 'item_name': item.name, 'karat': allocation.karat,
                'category_id': allocation.category_id, 'grams': round(float(allocation.grams), 3)}
        plan.append(step)
        if dry_run:
            continue
        line = db.session.get(JournalEntryLine, allocation.journal_entry_line_id)
        karat, category_id, grams = allocation.karat, allocation.category_id, float(allocation.grams)
        db.session.delete(allocation)
        db.session.flush()
        written = allocate(line, karat, category_id, grams, now=now, by=by)
        _audit(by, written.id, {**step, 'written_allocation_id': written.id, 'at': now})
    if not dry_run:
        db.session.flush()
    return {'allocations': plan, 'grams': round(sum(p['grams'] for p in plan), 3)}
