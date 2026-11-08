"""A piece is born on receiving, by one writer (ADR-087 R3, §5; ADR-085).

register_piece is the one place an Item that is a piece is made. A posted
receipt's line in a category tracked by the piece registers its pieces one
by one: each its own number «KJ-» and six digits or more, from a sequence
never reused (ADR-085 law 1); its weight, its stones; its line's category
and karat. The pieces of a line weigh no more than it: the rest stays weight
in its category (the owner, 8 Nov 2026). Nothing moves in the books: the
line's grams were allocated to its category on receiving; a piece takes its
share of that allocation under its own number -- the allocation's one
writer (services/stock_ledger.allocate), the row given up rewritten as it
was less the piece. The line is locked while its pieces are counted.
"""
from __future__ import annotations

from sqlalchemy import func

from models import (Category, Invoice, InvoiceItem, Item, JournalEntry, JournalEntryLine, PIECE_NUMBER,
                    StockLineAllocation, db)

GRAM = 0.0005
RECEIVED_STAGES = ('received', 'invoiced')


class PieceRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def pieces_weight(line: InvoiceItem) -> float:
    """The grams of the pieces registered under a receipt line."""
    return round(float(db.session.query(func.coalesce(func.sum(Item.weight), 0.0))
                       .filter(Item.receipt_item_id == line.id).scalar() or 0.0), 3)


def _receipt_stock_allocations(line: InvoiceItem, karat: int):
    """The receipt's category allocations of this line's karat with no piece
    yet -- the grams a piece takes its share from."""
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=line.invoice_id,
                                                          is_deleted=False)]
    lines = [l.id for l in JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries or [-1]),
                                                         JournalEntryLine.is_deleted.is_(False))]
    return (StockLineAllocation.query.filter(StockLineAllocation.journal_entry_line_id.in_(lines or [-1]),
                                             StockLineAllocation.karat == karat,
                                             StockLineAllocation.category_id == line.category_id,
                                             StockLineAllocation.item_id.is_(None),
                                             StockLineAllocation.grams > GRAM)
            .order_by(StockLineAllocation.id).all())


def register_piece(line: InvoiceItem, *, weight, stones_weight=0.0, by: str, now) -> Item:
    """One piece under a posted receipt's line -- or PieceRefused."""
    from services.stock_ledger import allocate

    line = InvoiceItem.query.with_for_update().get(line.id)      # its pieces counted alone
    invoice = db.session.get(Invoice, line.invoice_id)
    if (invoice is None or (invoice.invoice_type or '').strip() != 'شراء' or not invoice.is_posted
            or getattr(invoice, 'receiving_stage', None) not in RECEIVED_STAGES):
        raise PieceRefused('piece_line_not_received', 'القطعة تُسجَّل تحت سطر استلام مرحَّل قائم')
    category = db.session.get(Category, line.category_id) if line.category_id else None
    if category is None or (category.tracking or 'weight') != 'piece':
        raise PieceRefused('piece_category_by_weight', 'تصنيف السطر يُتابَع بالوزن: لا تُسجَّل فيه قطع')
    try:
        weight = round(float(weight), 3)
        stones = round(float(stones_weight or 0.0), 3)
    except (TypeError, ValueError):
        raise PieceRefused('piece_weight_invalid', 'وزن القطعة غير مفهوم') from None
    if weight <= GRAM or stones < 0 or stones >= weight:
        raise PieceRefused('piece_weight_invalid', 'وزن القطعة أكبر من صفر، وفصوصها أقل منه')
    rest = round(float(line.weight or 0.0) - pieces_weight(line), 3)
    if weight > rest + GRAM:
        raise PieceRefused('piece_heavier_than_rest',
                           f'القطعة ({weight:.2f} جم) أثقل من باقي السطر ({rest:.2f} جم)')
    karat = int(round(float(line.karat or 0)))

    number = db.session.execute(PIECE_NUMBER.next_value()).scalar()
    code = f'KJ-{int(number):06d}'
    piece = Item(item_code=code, barcode=code, name=category.name, category_id=category.id, karat=str(karat),
                 weight=weight, has_stones=stones > GRAM, stones_weight=stones, price=0.0, stock=1, count=1,
                 receipt_item_id=line.id, created_at=now, created_by=by)
    db.session.add(piece)
    db.session.flush()

    # Its share of the line's category allocation, under its number.
    left = weight
    for row in _receipt_stock_allocations(line, karat):
        if left <= GRAM:
            break
        take = round(min(left, float(row.grams)), 6)
        written_line = db.session.get(JournalEntryLine, row.journal_entry_line_id)
        remainder = round(float(row.grams) - take, 6)
        db.session.delete(row)
        db.session.flush()
        if remainder > GRAM:
            allocate(written_line, karat, category.id, remainder, now=now, by=by)
        allocate(written_line, karat, category.id, take, item_id=piece.id, now=now, by=by)
        left = round(left - take, 6)
    if left > GRAM:
        raise PieceRefused('piece_line_not_allocated',
                           'ذهب السطر غير موزَّع على تصنيفه في خزينة مخزون: لا يُسجَّل تحته قطع')
    db.session.flush()
    return piece
