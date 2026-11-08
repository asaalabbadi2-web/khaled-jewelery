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


def register_piece(line: InvoiceItem, *, weight, stones_weight=0.0, by: str, now, request_key=None) -> Item:
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
                 receipt_item_id=line.id, created_at=now, created_by=by, request_key=request_key or None)
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


def piece_held(item_id: int) -> float:
    """A piece's grams in the stock: its allocations on posted, standing lines
    -- its receipt put it in, a sale takes it out (ADR-045)."""
    from accounting.balances import counted_line_filters
    grams = (db.session.query(func.coalesce(func.sum(StockLineAllocation.grams), 0.0))
             .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(StockLineAllocation.item_id == int(item_id), *counted_line_filters())
             .scalar())
    return round(float(grams or 0.0), 3)


def refuse_piece_sales(invoice_type, items) -> None:
    """A sale's lines against the piece's laws, or PieceRefused (ADR-087 R3.2;
    ADR-045; ADR-085 law 3): a piece in the stock -- not sold twice; its
    receipt's invoice completed -- never sold with its wage unknown (law 8);
    the line its weight; a category tracked by the piece sold by its pieces."""
    if (invoice_type or '').strip() != 'بيع':
        return
    for n, line in enumerate(items or [], start=1):
        if not isinstance(line, dict):
            continue
        item_id = line.get('item_id')
        if not item_id:
            category = db.session.get(Category, int(line['category_id'])) if line.get('category_id') else None
            if category is not None and (category.tracking or 'weight') == 'piece':
                raise PieceRefused('piece_category_sold_by_piece',
                                   f'السطر {n}: «{category.name}» يُباع بقطعه: امسح رقم القطعة')
            continue
        piece = db.session.get(Item, int(item_id))
        if piece is None or piece.receipt_item_id is None:
            continue                                    # not a piece: the catalogue's own rules
        if piece_held(piece.id) <= GRAM:
            raise PieceRefused('piece_sold', f'السطر {n}: القطعة {piece.item_code} ليست في المخزون: لا تُباع مرتين')
        if piece_wage(piece) is None:
            raise PieceRefused('piece_wage_unknown',
                               f'السطر {n}: القطعة {piece.item_code} لم تُستكمل فاتورة استلامها: أجرتها غير معروفة')
        try:
            weight = round(float(line.get('weight')), 3)
        except (TypeError, ValueError):
            weight = 0.0
        if abs(weight - round(float(piece.weight or 0), 3)) > GRAM:
            raise PieceRefused('piece_weight_differs',
                               f'السطر {n}: القطعة {piece.item_code} تُباع بوزنها ({float(piece.weight):.2f} جم)')


# ── receiving alone makes a piece (ADR-087 §5, law 3; R3.3) ──────────────────

BORN_ON_RECEIVING = 'القطعة تولد في الاستلام وحده: سجّلها تحت سطر استلام، أو بالاستلام من المخزون الموجود'

# A piece's facts: what its allocations and its receipt say -- its wage its
# share of the line's (§6, law 5). Its name and description are words, edited
# from the catalogue; these are not.
PIECE_FIXED = ('item_code', 'barcode', 'weight', 'stones_weight', 'karat', 'category_id', 'count', 'stock',
               'wage', 'manufacturing_wage_per_gram', 'price')


def refuse_inline_items(items) -> None:
    """No invoice makes an item (its create_inline closed): PieceRefused."""
    for line in items or []:
        if isinstance(line, dict) and line.get('create_inline'):
            raise PieceRefused('piece_born_on_receiving', BORN_ON_RECEIVING)


def refuse_catalogue_item(now) -> None:
    """The catalogue adds no item while receiving is on: PieceRefused. In 2026,
    with no receiving, it adds as it did -- until the sunset (R6)."""
    from services.receiving import receiving_on
    if receiving_on(now):
        raise PieceRefused('piece_born_on_receiving', BORN_ON_RECEIVING)


def _same(fact, before, after) -> bool:
    if after in (None, '') and before in (None, ''):
        return True
    if fact in ('weight', 'stones_weight', 'count', 'stock', 'karat', 'wage', 'manufacturing_wage_per_gram',
                'price'):
        try:
            return abs(float(str(after)) - float(before or 0)) <= GRAM
        except (TypeError, ValueError):
            return False
    if fact == 'category_id':
        return (int(after) if after not in (None, '') else None) == before
    return str(after).strip() == str(before or '').strip()


def refuse_piece_edit(item: Item, data: dict) -> None:
    """A piece's book facts are not edited from the catalogue: PieceRefused.
    A fact sent as it is (the edit screen sends the whole item) is not a change."""
    if item.receipt_item_id is None:
        return
    for fact in PIECE_FIXED:
        if fact in (data or {}) and not _same(fact, getattr(item, fact), data[fact]):
            raise PieceRefused('piece_fixed', f'لا يُعدَّل في القطعة {item.item_code} إلا اسمها ووصفها')


def refuse_piece_delete(item: Item) -> None:
    """A piece is not deleted: its allocations in the books name it."""
    if item.receipt_item_id is not None:
        raise PieceRefused('piece_not_deleted', f'القطعة {item.item_code} لا تُحذف: الدفاتر تذكرها')


# ── a category's tracking (ADR-087 §5, §6; R3.4) ─────────────────────────────

TRACKINGS = ('weight', 'piece')


def category_pieces_held(category_id: int) -> int:
    """How many pieces of the category are in the stock."""
    return sum(1 for (item_id,) in db.session.query(Item.id).filter(Item.category_id == int(category_id),
                                                                   Item.receipt_item_id.isnot(None))
               if piece_held(item_id) > GRAM)


def set_tracking(category: Category, *, tracking=None) -> None:
    """How a category is tracked -- or PieceRefused. Back to weight while a
    piece of it is held is refused: its pieces would be sold by weight; a
    scrap category is never by the piece."""
    if tracking is None:
        return
    tracking = str(tracking).strip()
    if tracking not in TRACKINGS or (tracking == 'piece' and category.is_scrap):
        raise PieceRefused('category_tracking_invalid', 'طريقة التتبّع بالوزن أو بالقطعة، وتصنيف الكسر بالوزن')
    if tracking == 'weight' and (category.tracking or 'weight') == 'piece':
        held = category_pieces_held(category.id)
        if held:
            raise PieceRefused('category_has_pieces',
                               f'«{category.name}» فيه {held} قطعة في المخزون: يبقى بالقطعة حتى تخرج')
    category.tracking = tracking


# ── the wage: read, never kept (§6) ──────────────────────────────────────────

def line_pieces(line: InvoiceItem):
    return Item.query.filter(Item.receipt_item_id == line.id).order_by(Item.id).all()


def line_wages(line: InvoiceItem):
    """The line's wage and its shares, to the halala (law 5) -- or None while
    its invoice is not completed. The wage is per gram, always (the owner,
    9 Nov 2026): bullion's too -- its line's wage given whole is divided by
    its weight, one line per bar size. Each piece its line's wage per gram
    times its weight; the rest -- the weight not coded -- what is left; no
    rest, the last piece takes the rounding."""
    invoice = db.session.get(Invoice, line.invoice_id)
    if invoice is None or getattr(invoice, 'receiving_stage', None) != 'invoiced':
        return None
    per_gram = float(line.wage or 0.0)
    total = round(per_gram * float(line.weight or 0.0), 2)
    pieces = line_pieces(line)
    shares = {p.id: round(per_gram * float(p.weight or 0.0), 2) for p in pieces}
    rest_weight = round(float(line.weight or 0.0) - sum(float(p.weight or 0.0) for p in pieces), 3)
    rest = round(total - sum(shares.values()), 2)
    if rest_weight <= GRAM and pieces:
        shares[pieces[-1].id] = round(shares[pieces[-1].id] + rest, 2)
        rest = 0.0
    return {'line': total, 'pieces': shares, 'rest': rest, 'per_gram': per_gram}


def piece_wage(piece: Item):
    """A piece's wage, from its line -- None while unknown (law 8)."""
    if piece.receipt_item_id is None:
        return None
    line = db.session.get(InvoiceItem, piece.receipt_item_id)
    wages = line_wages(line) if line is not None else None
    return None if wages is None else wages['pieces'].get(piece.id)


# ── the station (R3.4) ───────────────────────────────────────────────────────

def line_view(line: InvoiceItem) -> dict:
    """A receipt line as the station shows it: its document, its category,
    its weight, its pieces and its rest."""
    from models import Supplier
    invoice = db.session.get(Invoice, line.invoice_id)
    category = db.session.get(Category, line.category_id) if line.category_id else None
    supplier = db.session.get(Supplier, invoice.supplier_id) if invoice and invoice.supplier_id else None
    pieces = line_pieces(line)
    coded = round(sum(float(p.weight or 0.0) for p in pieces), 3)
    return {'line_id': line.id, 'invoice_id': line.invoice_id,
            'invoice_number': getattr(invoice, 'invoice_number', None),
            'date': invoice.date.isoformat() if invoice and invoice.date else None,
            'stage': getattr(invoice, 'receiving_stage', None),
            'supplier_name': getattr(supplier, 'name', None),
            'category_id': line.category_id, 'category_name': getattr(category, 'name', None),
            'karat': int(round(float(line.karat or 0))), 'weight': round(float(line.weight or 0.0), 3),
            'pieces': len(pieces), 'pieces_weight': coded, 'rest': round(float(line.weight or 0.0) - coded, 3)}


def piece_view(piece: Item) -> dict:
    wage = piece_wage(piece)
    return {'id': piece.id, 'item_code': piece.item_code, 'barcode': piece.barcode, 'name': piece.name,
            'karat': piece.karat, 'weight': round(float(piece.weight or 0.0), 3),
            'stones_weight': round(float(piece.stones_weight or 0.0), 3), 'line_id': piece.receipt_item_id,
            'wage': wage, 'wage_known': wage is not None, 'in_stock': piece_held(piece.id) > GRAM,
            'created_at': piece.created_at.isoformat() if piece.created_at else None,
            'created_by': piece.created_by}


def pending_lines() -> list[dict]:
    """The station's list: posted receipt lines of categories tracked by the
    piece with weight left to code, oldest first."""
    rows = (InvoiceItem.query.join(Invoice, Invoice.id == InvoiceItem.invoice_id)
            .join(Category, Category.id == InvoiceItem.category_id)
            .filter(Invoice.is_posted.is_(True), Invoice.receiving_stage.in_(RECEIVED_STAGES),
                    Category.tracking == 'piece')
            .order_by(Invoice.date, InvoiceItem.id).all())
    views = (line_view(line) for line in rows)
    return [v for v in views if v['rest'] > GRAM]
