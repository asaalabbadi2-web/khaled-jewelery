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
