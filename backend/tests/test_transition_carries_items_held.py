"""2027 opens with the items its stock holds, no others (the owner, 8 Nov 2026).

The transition copied the whole item table into 2027 as master data: the 19
purchase lots the screen made items (I-000001 «سلاسل حبل ومبروم» 139 g...),
I-000002 «ذهب صافي عيار 24» -- «سبايك ذهب عيار 24 تنوب عنه ولم يعد له لزوم» --
and, from 2027, every piece ever sold. An item goes when the stock holds it at
the close: its allocations on posted lines add to more than nothing. A piece
sold (its sale's allocation takes it back to nothing) or a lot given back to
its category (services/repair/lot_items) stays in 2026's archive.

Run:
    python -m pytest tests/test_transition_carries_items_held.py -v
"""
import uuid

from models import Item, JournalEntry, JournalEntryLine, StockLineAllocation, db
from services.transition_2027 import _items_held, _skip
from tests.test_stock_count import NOW, _category, _safe, _stock, _uid
from tests.test_stock_count import app, rollback_after_each  # noqa: F401 -- the module's fixtures


def _item(category):
    item = Item(item_code=f'KJ-{uuid.uuid4().int % 10**6:06d}', name='بنجرة', karat='21', weight=14.37, price=0.0,
                category_id=category.id)
    db.session.add(item)
    db.session.flush()
    return item


def _held(box, item, grams):
    """Grams of the item on a posted stock line: in (positive) or out (negative)."""
    from services.stock_ledger import allocate
    je = JournalEntry(entry_number=f'JE-I-{_uid()}', date=NOW, description='قطعة', entry_type='عادي',
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    side = 'debit_21k' if grams > 0 else 'credit_21k'
    line = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, description='قطعة',
                            **{side: abs(grams)})
    db.session.add(line)
    db.session.flush()
    allocate(line, 21, item.category_id, grams, item_id=item.id, by='t', now=NOW)


def test_an_item_the_stock_holds_goes_one_it_does_not_hold_stays(app):
    box, bangles = _safe(), _category()
    held, sold, never = _item(bangles), _item(bangles), _item(bangles)
    _held(box, held, 14.37)
    _held(box, sold, 12.0)
    _held(box, sold, -12.0)            # its sale
    items = _items_held(db.session.connection())
    assert held.id in items
    assert sold.id not in items and never.id not in items
    ex = {'items': items}
    assert _skip('item', {'id': held.id}, ex) is False
    assert _skip('item', {'id': sold.id}, ex) is True


# ── what a carried row names is carried too (the owner, 27 Nov 2026: «ابدأ بها») ────────────────────
# Built on 7 Nov, the transition carried the categories and the pieces held but not what they came to
# name after it: the sections (21 Nov) 40 categories name in production, the size systems and models
# (18 Nov), the chips (20 Nov). Its insert would be refused by the first foreign key, and the pieces
# coded before the 31 Dec count would open 2027 without their chips -- «ليست من رموزنا» on the reader.

def test_every_reference_of_a_carried_row_is_carried_or_cleared():
    """Each foreign key of a carried table: to a carried table, to an account it maps to 2027's, or
    named cleared -- a 2026 document that stays in the archive. A table that comes to be named later
    is caught here, not on 1 January."""
    from services.transition_2027 import CLEARED, MASTER
    carried = {table for table, _ in MASTER}
    loose = []
    for table, columns in MASTER:
        for column in db.metadata.tables[table].columns:
            for fk in column.foreign_keys:
                target = fk.column.table.name
                if target in carried or (table, column.name) in CLEARED or columns.get(column.name) == 'account':
                    continue
                loose.append(f'{table}.{column.name} -> {target}')
    assert not loose, f'named by a carried row, neither carried nor cleared: {loose}'


def test_a_held_pieces_chips_go_with_it_and_a_sold_ones_stay(app):
    from models import PieceTag
    from services.pieces import epc_of
    box, bangles = _safe(), _category()
    held, sold = _item(bangles), _item(bangles)
    _held(box, held, 14.37)
    _held(box, sold, 12.0)
    _held(box, sold, -12.0)
    for piece in (held, sold):
        db.session.add(PieceTag(item_id=piece.id, value=epc_of(piece.item_code), technology='uhf_epc96',
                                mounted_at=NOW, mounted_by='t', generation=0))
    db.session.flush()
    ex = {'items': _items_held(db.session.connection()), 'attachments': set()}
    tags = {t.item_id: t for t in PieceTag.query.filter(PieceTag.item_id.in_([held.id, sold.id]))}
    assert _skip('piece_tag', {'id': tags[held.id].id, 'item_id': held.id}, ex) is False
    assert _skip('piece_tag', {'id': tags[sold.id].id, 'item_id': sold.id}, ex) is True


def test_only_the_photos_a_model_shows_go():
    from services.transition_2027 import _skip as skip
    ex = {'items': set(), 'attachments': {7}}
    assert skip('attachment', {'id': 7}, ex) is False, 'a model\'s photo'
    assert skip('attachment', {'id': 8}, ex) is True, 'a document\'s, kept in 2026\'s archive'


def test_a_carried_pieces_2026_documents_are_cleared():
    from services.transition_2027 import CLEARED
    assert {('item', 'receipt_item_id'), ('item', 'coding_id'), ('item', 'split_part_id'),
            ('piece_tag', 'attempt_id')} <= CLEARED, 'its receipt, batch, split and print attempt stay in 2026'
