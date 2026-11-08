"""The purchase lots made items give their item back to their category (the owner, 8 Nov 2026).

The purchase screen made each typed line an item (create_inline) until
5303e152: 18 lots on the 5 Nov copy, «I-» numbered, in the table that holds
the piece (ADR-085), two of them on the stock -- I-000017 33 g, I-000019
72.22 g -- and the transition carries an allocation's item into 2027. Each
allocation carrying an «I-» item is written again by the one writer
(stock_ledger.allocate), the same line, karat, category and grams, without
the item; the category's grams do not move. A piece (any other number) is
left. Dry run by default; a second run finds nothing.

Run:
    python -m pytest tests/test_lot_items_released.py -v
"""
import uuid

from models import Item, StockLineAllocation, db
from tests.test_stock_count import NOW, _category, _safe, _stock
from tests.test_stock_count import app, rollback_after_each  # noqa: F401 -- the module's fixtures


def _item(code, category):
    item = Item(item_code=code, name='اطقم سلم', karat='21', weight=33.0, price=0.0, category_id=category.id)
    db.session.add(item)
    db.session.flush()
    return item


def _held_by(item):
    return [(a.journal_entry_line_id, a.karat, a.category_id, a.grams)
            for a in StockLineAllocation.query.filter_by(item_id=item.id)]


def _of_category(category):
    return round(sum(a.grams for a in StockLineAllocation.query.filter_by(category_id=category.id)), 3)


def test_a_lot_gives_its_item_back_its_grams_stay_in_the_category(app):
    from services.repair.lot_items import release_lot_items
    box, sets = _safe(), _category()
    lot = _item(f'I-{uuid.uuid4().hex[:6]}', sets)
    _stock(box, 33.0, sets)
    StockLineAllocation.query.filter_by(category_id=sets.id).update({'item_id': lot.id})
    before = _of_category(sets)
    planned = release_lot_items(by='t', now=NOW, dry_run=True)
    assert [a['item_code'] for a in planned['allocations']] == [lot.item_code]
    assert _held_by(lot), 'a dry run writes nothing'
    done = release_lot_items(by='t', now=NOW, dry_run=False)
    assert done['grams'] == 33.0
    assert _held_by(lot) == [], 'no allocation carries the lot'
    assert _of_category(sets) == before, 'the category keeps its grams'
    assert release_lot_items(by='t', now=NOW, dry_run=False)['allocations'] == [], 'a second run finds nothing'


def test_a_piece_is_left(app):
    from services.repair.lot_items import release_lot_items
    box, sets = _safe(), _category()
    piece = _item(f'KJ-{uuid.uuid4().int % 10**6:06d}', sets)
    _stock(box, 14.37, sets)
    StockLineAllocation.query.filter_by(category_id=sets.id).update({'item_id': piece.id})
    release_lot_items(by='t', now=NOW, dry_run=False)
    assert len(_held_by(piece)) == 1
