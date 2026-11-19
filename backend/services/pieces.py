"""A piece is born on receiving, by one writer (ADR-087 R3, §5; ADR-085).

register_piece is the one place an Item that is a piece is made. Its source
is a posted receipt's line in a category tracked by the piece, or a batch of
the stock a location already holds (StockCoding, R3.5). It registers its
pieces one by one: each its own number «KJ-» and six digits or more, from a sequence
never reused (ADR-085 law 1); its weight, its stones; its line's category
and karat. The pieces of a line weigh no more than it: the rest stays weight
in its category (the owner, 8 Nov 2026). Nothing moves in the books: the
line's grams were allocated to its category on receiving; a piece takes its
share of that allocation under its own number -- the allocation's one
writer (services/stock_ledger.allocate), the row given up rewritten as it
was less the piece. A batch's pieces take theirs from the allocations of
its category its location holds, not yet pieced. The source is locked while
its pieces are counted.
"""
from __future__ import annotations

import json
import re

from sqlalchemy import func, or_

from models import (Category, Invoice, InvoiceItem, Item, JournalEntry, JournalEntryLine, PIECE_NUMBER,
                    PieceTag, SafeBox, StockCoding, StockLineAllocation, db)

GRAM = 0.0005
RECEIVED_STAGES = ('received', 'invoiced')


class PieceRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def is_piece(item) -> bool:
    """An item born a piece: under a receipt line or in a batch of stock."""
    return item is not None and (item.receipt_item_id is not None or getattr(item, 'coding_id', None) is not None)


def _source_filter(source):
    return (Item.coding_id == source.id) if isinstance(source, StockCoding) else (Item.receipt_item_id == source.id)


def pieces_weight(source) -> float:
    """The grams of the pieces registered under a receipt line, or a batch."""
    return round(float(db.session.query(func.coalesce(func.sum(Item.weight), 0.0))
                       .filter(_source_filter(source)).scalar() or 0.0), 3)


def returned_loose(line) -> float:
    """The grams of a receipt line its supplier returns took back under no
    piece -- every return not rejected (the owner, 18 Nov 2026)."""
    return round(float(db.session.query(func.coalesce(func.sum(InvoiceItem.weight), 0.0))
                       .join(Invoice, Invoice.id == InvoiceItem.invoice_id)
                       .filter(InvoiceItem.original_invoice_item_id == line.id, InvoiceItem.item_id.is_(None),
                               Invoice.invoice_type == 'مرتجع شراء (مورد)',
                               or_(Invoice.status.is_(None), Invoice.status != 'rejected'))
                       .scalar() or 0.0), 3)


def line_rest(line) -> float:
    """What of a receipt line is neither a piece nor returned to its supplier
    loose: what may still be coded, or returned under no piece -- one reading
    for both, so gold returned is not coded and a piece's gold not returned."""
    return round(float(line.weight or 0.0) - pieces_weight(line) - returned_loose(line), 3)


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


def _free_allocations(safe_box: SafeBox, karat: int, category_id: int):
    """A location's allocations of a category and karat on posted, standing
    lines, no piece yet, outside the receipts -- the grams a batch's piece
    takes its share from. A receipt's grams are its own lines' to code: their
    wage is its invoice's, not the batch's."""
    from sqlalchemy import or_, select
    from accounting.balances import counted_line_filters
    receipts = select(Invoice.id).where(Invoice.receiving_stage.in_(RECEIVED_STAGES))
    return (StockLineAllocation.query
            .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntryLine.account_id == safe_box.account_id, StockLineAllocation.karat == int(karat),
                    StockLineAllocation.category_id == int(category_id), StockLineAllocation.item_id.is_(None),
                    # NULL-safe: an entry with no reference (the opening's) is outside them
                    or_(JournalEntry.reference_type.is_(None), JournalEntry.reference_type != 'invoice',
                        JournalEntry.reference_id.is_(None), JournalEntry.reference_id.notin_(receipts)),
                    *counted_line_filters()))


def free_grams(safe_box: SafeBox, karat: int, category_id: int) -> float:
    """What a location holds of a category and karat not yet pieced, outside
    the receipts."""
    rows = _free_allocations(safe_box, karat, category_id).all()
    return round(sum(float(r.grams) for r in rows), 3)


def _source_of(source):
    """The source, locked, its category, karat and the refusal if it is not
    one a piece is born under."""
    if isinstance(source, StockCoding):
        source = StockCoding.query.with_for_update().get(source.id)
        return source, db.session.get(Category, source.category_id), int(source.karat)
    line = InvoiceItem.query.with_for_update().get(source.id)      # its pieces counted alone
    invoice = db.session.get(Invoice, line.invoice_id)
    if (invoice is None or (invoice.invoice_type or '').strip() != 'شراء' or not invoice.is_posted
            or getattr(invoice, 'receiving_stage', None) not in RECEIVED_STAGES):
        raise PieceRefused('piece_line_not_received', 'القطعة تُسجَّل تحت سطر استلام مرحَّل قائم')
    category = db.session.get(Category, line.category_id) if line.category_id else None
    return line, category, int(round(float(line.karat or 0)))


def model_and_size(category: Category, model_id=None, size_id=None):
    """A piece's model and size (ADR-093 §3), or PieceRefused: the model of its
    category and running; the size of its category's size system, and of the
    model's sizes when the model names its sizes."""
    from models import PieceModel, PieceModelSize, SizeSystemSize
    model = size = None
    if model_id not in (None, '', 0, '0'):
        model = db.session.get(PieceModel, int(model_id))
        if model is None:
            raise PieceRefused('model_not_found', 'الموديل غير موجود')
        if model.category_id != category.id:
            raise PieceRefused('model_category_differs', f'الموديل «{model.name}» ليس من «{category.name}»')
        if model.is_active is False:
            raise PieceRefused('model_stopped', f'الموديل «{model.name}» موقوف')
    if size_id not in (None, '', 0, '0'):
        size = db.session.get(SizeSystemSize, int(size_id))
        if size is None or category.size_system_id is None or size.system_id != category.size_system_id:
            raise PieceRefused('size_not_in_category', f'المقاس ليس من نظام مقاسات «{category.name}»')
        if model is not None:
            sizes = {r.size_id for r in PieceModelSize.query.filter_by(model_id=model.id)}
            if sizes and size.id not in sizes:
                raise PieceRefused('size_not_in_model', f'المقاس {size.label} ليس من مقاسات «{model.name}»')
    return model, size


def _written_wage(wage, wage_whole, weight: float) -> float:
    """The wage written for a piece coded from the stock on hand, riyals for
    the whole piece -- per gram times its weight, or the whole as written; or
    PieceRefused. Zero is a wage, none is not."""
    if wage is None or (isinstance(wage, str) and not wage.strip()):
        raise PieceRefused('piece_wage_required', 'اكتب أجرة القطعة: بالجرام أو للقطعة كلها')
    try:
        wage = float(wage)
    except (TypeError, ValueError):
        raise PieceRefused('piece_wage_invalid', 'أجرة القطعة غير مفهومة') from None
    if wage < 0:
        raise PieceRefused('piece_wage_invalid', 'أجرة القطعة صفر أو أكثر')
    return round(wage if wage_whole else wage * weight, 2)


def register_piece(source, *, weight, stones_weight=0.0, model_id=None, size_id=None, wage=None,
                   wage_whole=False, by: str, now, request_key=None) -> Item:
    """One piece under a posted receipt's line or a batch of stock -- or PieceRefused.
    Its model and size describe it (ADR-093). A receipt's piece takes its
    invoice's wage (§6): none is written for it. A batch's piece is written its
    own -- `wage` per gram, or the piece's whole with `wage_whole` (ADR-096 §4)."""
    from services.stock_ledger import allocate

    source, category, karat = _source_of(source)
    batch = isinstance(source, StockCoding)
    if category is None or (category.tracking or 'weight') != 'piece':
        raise PieceRefused('piece_category_by_weight', 'تصنيف السطر يُتابَع بالوزن: لا تُسجَّل فيه قطع')
    model, size = model_and_size(category, model_id, size_id)
    try:
        weight = round(float(weight), 3)
        stones = round(float(stones_weight or 0.0), 3)
    except (TypeError, ValueError):
        raise PieceRefused('piece_weight_invalid', 'وزن القطعة غير مفهوم') from None
    if weight <= GRAM or stones < 0 or stones >= weight:
        raise PieceRefused('piece_weight_invalid', 'وزن القطعة أكبر من صفر، وفصوصها أقل منه')
    if batch:
        coded_wage = _written_wage(wage, wage_whole, weight)
    elif wage is not None and not (isinstance(wage, str) and not wage.strip()):
        raise PieceRefused('piece_wage_from_invoice', 'قطعة الاستلام تأخذ أجرة فاتورتها: لا تُكتب لها أجرة')
    rest = (round(float(source.weight or 0.0) - pieces_weight(source), 3) if batch else line_rest(source))
    if weight > rest + GRAM:
        raise PieceRefused('piece_heavier_than_rest',
                           f'القطعة ({weight:.2f} جم) أثقل من باقي {"الدفعة" if batch else "السطر"} ({rest:.2f} جم)')
    if batch:
        safe = db.session.get(SafeBox, source.safe_box_id)
        free = free_grams(safe, karat, category.id)
        if weight > free + GRAM:
            raise PieceRefused('piece_more_than_held',
                               f'القطعة ({weight:.2f} جم) أثقل مما في «{safe.name}» من «{category.name}» '
                               f'خارج الاستلامات بلا ترميز ({free:.2f} جم)')
        rows = (_free_allocations(safe, karat, category.id).filter(StockLineAllocation.grams > GRAM)
                .order_by(StockLineAllocation.id).all())
    else:
        rows = _receipt_stock_allocations(source, karat)

    number = db.session.execute(PIECE_NUMBER.next_value()).scalar()
    code = f'KJ-{int(number):06d}'
    piece = Item(item_code=code, barcode=code, name=model.name if model else category.name,
                 category_id=category.id, karat=str(karat), model_id=model.id if model else None,
                 size_id=size.id if size else None,
                 weight=weight, has_stones=stones > GRAM, stones_weight=stones, price=0.0, stock=1, count=1,
                 receipt_item_id=None if batch else source.id, coding_id=source.id if batch else None,
                 coded_wage=coded_wage if batch else None,
                 created_at=now, created_by=by, request_key=request_key or None)
    db.session.add(piece)
    db.session.flush()

    # Its share of the category's allocation, under its number.
    left = weight
    for row in rows:
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
    the line its weight and its invoice's wage per gram; a category tracked
    by the piece sold by its pieces."""
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
        if not is_piece(piece):
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
        # its wage is its invoice's (§6), and the sale releases wage x weight
        # from the wages' stock to the expense: a wage typed is a wrong entry
        # (the owner, 18 Nov 2026)
        per_gram = piece_wage_per_gram(piece)
        try:
            sent = float(line.get('wage'))
        except (TypeError, ValueError):
            sent = None
        if sent is None or abs(sent - per_gram) > 0.0005:
            raise PieceRefused('piece_wage_differs',
                               f'السطر {n}: القطعة {piece.item_code} تُباع بأجرة فاتورتها ({per_gram:.2f} للجرام)')


# ── receiving alone makes a piece (ADR-087 §5, law 3; R3.3) ──────────────────

BORN_ON_RECEIVING = 'القطعة تولد في الاستلام وحده: سجّلها تحت سطر استلام، أو بالاستلام من المخزون الموجود'

# A piece's facts: what its allocations and its receipt say -- its wage its
# share of the line's (§6, law 5). Its name and description are words, edited
# from the catalogue; these are not.
PIECE_FIXED = ('item_code', 'barcode', 'weight', 'stones_weight', 'karat', 'category_id', 'count', 'stock',
               'wage', 'manufacturing_wage_per_gram', 'price', 'coded_wage')


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
                'price', 'coded_wage'):
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
    if not is_piece(item):
        return
    for fact in PIECE_FIXED:
        if fact in (data or {}) and not _same(fact, getattr(item, fact), data[fact]):
            raise PieceRefused('piece_fixed', f'لا يُعدَّل في القطعة {item.item_code} إلا اسمها ووصفها')


_KEEP = object()


def update_piece_words(piece: Item, *, name=_KEEP, description=_KEEP, model_id=_KEEP, size_id=_KEEP,
                       by: str, now) -> dict:
    """A piece's words: its name, its description, its model and its size
    (ADR-093 §5) -- descriptions, edited and recorded; its book facts stay
    (PIECE_FIXED). Its model and size by model_and_size's laws, against what
    it will be. Returns what changed, {fact: [before, after]}; the caller commits."""
    from models import AuditLog, PieceModel, SizeSystemSize
    if not is_piece(piece):
        raise PieceRefused('piece_not_found', 'ليست قطعة')
    category = db.session.get(Category, piece.category_id)
    new_model = piece.model_id if model_id is _KEEP else (int(model_id) if model_id not in (None, '', 0) else None)
    new_size = piece.size_id if size_id is _KEEP else (int(size_id) if size_id not in (None, '', 0) else None)
    if new_model != piece.model_id or new_size != piece.size_id:
        model_and_size(category, new_model, new_size)

    def label(kind, value):
        if value is None:
            return None
        row = db.session.get(PieceModel if kind == 'model' else SizeSystemSize, value)
        return getattr(row, 'name' if kind == 'model' else 'label', None)

    changed = {}
    if name is not _KEEP:
        text = re.sub(r'\s+', ' ', str(name or '')).strip()
        if not text:
            raise PieceRefused('piece_name_empty', 'اكتب اسم القطعة')
        if text != (piece.name or ''):
            changed['name'] = [piece.name, text[:100]]
            piece.name = text[:100]
    if description is not _KEEP:
        text = str(description or '').strip()[:200] or None
        if text != (piece.description or None):
            changed['description'] = [piece.description, text]
            piece.description = text
    if new_model != piece.model_id:
        changed['model'] = [label('model', piece.model_id), label('model', new_model)]
        piece.model_id = new_model
    if new_size != piece.size_id:
        changed['size'] = [label('size', piece.size_id), label('size', new_size)]
        piece.size_id = new_size
    if changed:
        db.session.flush()
        AuditLog.log_action(user_name=by, action='piece_words_edited', entity_type='Item', entity_id=piece.id,
                            entity_number=piece.item_code,
                            details=json.dumps({'changed': changed, 'at': now.isoformat()}, ensure_ascii=False))
    return changed


def refuse_piece_delete(item: Item) -> None:
    """A piece is not deleted: its allocations in the books name it."""
    if is_piece(item):
        raise PieceRefused('piece_not_deleted', f'القطعة {item.item_code} لا تُحذف: الدفاتر تذكرها')


# ── a category's tracking (ADR-087 §5, §6; R3.4) ─────────────────────────────

TRACKINGS = ('weight', 'piece')


def category_pieces_held(category_id: int) -> int:
    """How many pieces of the category are in the stock."""
    from sqlalchemy import or_
    return sum(1 for (item_id,) in db.session.query(Item.id).filter(
                   Item.category_id == int(category_id),
                   or_(Item.receipt_item_id.isnot(None), Item.coding_id.isnot(None)))
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


# ── the wage: a receipt's piece reads its line's (§6); a batch's keeps its own ─

def line_pieces(source):
    """The pieces of a receipt line or a batch, in their order."""
    return Item.query.filter(_source_filter(source)).order_by(Item.id).all()


def _shares(source, per_gram: float):
    """Law 5, to the halala: each piece its wage per gram times its weight;
    the rest -- the weight not coded -- what is left; no rest, the last piece
    takes the rounding."""
    total = round(per_gram * float(source.weight or 0.0), 2)
    pieces = line_pieces(source)
    shares = {p.id: round(per_gram * float(p.weight or 0.0), 2) for p in pieces}
    rest_weight = round(float(source.weight or 0.0) - sum(float(p.weight or 0.0) for p in pieces), 3)
    rest = round(total - sum(shares.values()), 2)
    if rest_weight <= GRAM and pieces:
        shares[pieces[-1].id] = round(shares[pieces[-1].id] + rest, 2)
        rest = 0.0
    return {'line': total, 'pieces': shares, 'rest': rest, 'per_gram': per_gram}


def line_wages(source):
    """The source's wage and its shares (law 5) -- or None while unknown. A
    receipt line's is its invoice's, per gram always (the owner, 9 Nov 2026):
    bullion's too -- its line's wage given whole is divided by its weight, one
    line per bar size; unknown until the invoice is completed. A batch's is
    its pieces' own, each written at its coding (ADR-096 §4): no wage per
    gram, nothing left over."""
    if isinstance(source, StockCoding):
        shares = {p.id: round(float(p.coded_wage or 0.0), 2) for p in line_pieces(source)}
        return {'line': round(sum(shares.values()), 2), 'pieces': shares, 'rest': 0.0, 'per_gram': None}
    invoice = db.session.get(Invoice, source.invoice_id)
    if invoice is None or getattr(invoice, 'receiving_stage', None) != 'invoiced':
        return None
    return _shares(source, float(source.wage or 0.0))


def piece_source(piece: Item):
    if piece.coding_id is not None:
        return db.session.get(StockCoding, piece.coding_id)
    if piece.receipt_item_id is not None:
        return db.session.get(InvoiceItem, piece.receipt_item_id)
    return None


def source_wage_per_gram(source):
    """A receipt line's wage per gram once its invoice is completed -- None
    while unknown (law 8), and for a batch, whose pieces each have their own."""
    wages = line_wages(source)
    if wages is None or wages['per_gram'] is None:
        return None
    # unrounded: the sale releases wage x weight, and 12.333 rounded to 12.33
    # would leave 0.03 of a 10.01 g piece's wage in the wages' stock
    return round(float(wages['per_gram']), 6)


def piece_wage_per_gram(piece: Item):
    """A piece's wage per gram, as a sale line reads it: its receipt line's,
    or its own over its weight, unrounded -- None while unknown (law 8)."""
    source = piece_source(piece)
    if isinstance(source, StockCoding):
        weight = float(piece.weight or 0.0)
        return None if piece.coded_wage is None or weight <= GRAM else round(float(piece.coded_wage) / weight, 6)
    return source_wage_per_gram(source) if source is not None else None


def wages_per_gram(pieces) -> dict:
    """{piece id: its wage per gram -- its receipt line's once the invoice is
    completed, a batch's piece its own; None while unknown (law 8)} -- one
    reading a receipt line, for the lists that show many pieces."""
    by_line: dict = {}
    out = {}
    for piece in pieces:
        if piece.receipt_item_id:
            by_line.setdefault(piece.receipt_item_id, []).append(piece.id)
        elif getattr(piece, 'coding_id', None):
            out[piece.id] = piece_wage_per_gram(piece)
    for line_id, ids in by_line.items():
        line = db.session.get(InvoiceItem, line_id)
        per_gram = source_wage_per_gram(line) if line is not None else None
        out.update({i: per_gram for i in ids})
    return out


WAGE_SAME, WAGE_DIFFERS, WAGE_AWAITING, WAGE_NO_EXPECTED = 'same', 'model_wage_differs', 'awaiting_invoice', \
    'no_expected'
WAGE_BY_PIECE = 'by_piece'      # a batch: each piece its own wage, the model's expected beside it


def wage_check(source, model) -> dict:
    """The source's wage per gram against the model's expected one (ADR-093
    §1) -- a warning, never a refusal: the piece's wage is its source's."""
    expected = float(model.expected_wage_per_gram) if model is not None and \
        model.expected_wage_per_gram is not None else None
    if isinstance(source, StockCoding):
        return {'state': WAGE_BY_PIECE, 'invoice_per_gram': None, 'expected_per_gram': expected}
    actual = source_wage_per_gram(source)
    if expected is None:
        state = WAGE_NO_EXPECTED
    elif actual is None:
        state = WAGE_AWAITING
    else:
        state = WAGE_DIFFERS if abs(actual - expected) > 0.005 else WAGE_SAME
    return {'state': state, 'invoice_per_gram': actual, 'expected_per_gram': expected}


def piece_wage(piece: Item):
    """A piece's wage, from its source -- None while unknown (law 8)."""
    source = piece_source(piece)
    wages = line_wages(source) if source is not None else None
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
    return {'kind': 'receipt', 'line_id': line.id, 'coding_id': None, 'invoice_id': line.invoice_id,
            'invoice_number': getattr(invoice, 'invoice_number', None),
            'date': invoice.date.isoformat() if invoice and invoice.date else None,
            'stage': getattr(invoice, 'receiving_stage', None),
            'supplier_name': getattr(supplier, 'name', None),
            'category_id': line.category_id, 'category_name': getattr(category, 'name', None),
            'karat': int(round(float(line.karat or 0))), 'weight': round(float(line.weight or 0.0), 3),
            'size_system_id': getattr(category, 'size_system_id', None),
            'wage_per_gram': source_wage_per_gram(line), 'wage_by_piece': False,
            'pieces': len(pieces), 'pieces_weight': coded, 'returned_loose': returned_loose(line),
            'rest': line_rest(line)}


def piece_view(piece: Item) -> dict:
    from models import PieceModel, SizeSystemSize
    wage = piece_wage(piece)
    tag = active_tag(piece)
    model = db.session.get(PieceModel, piece.model_id) if getattr(piece, 'model_id', None) else None
    size = db.session.get(SizeSystemSize, piece.size_id) if getattr(piece, 'size_id', None) else None
    return {'id': piece.id, 'item_code': piece.item_code, 'barcode': piece.barcode, 'name': piece.name,
            'model': {'id': model.id, 'name': model.name} if model else None,
            'size': {'id': size.id, 'label': size.label} if size else None,
            'karat': piece.karat, 'weight': round(float(piece.weight or 0.0), 3),
            'stones_weight': round(float(piece.stones_weight or 0.0), 3), 'line_id': piece.receipt_item_id,
            'coding_id': piece.coding_id,
            'wage': wage, 'wage_known': wage is not None, 'in_stock': piece_held(piece.id) > GRAM,
            'created_at': piece.created_at.isoformat() if piece.created_at else None,
            'created_by': piece.created_by, 'tag': tag.value if tag is not None else None}


def coded_lines(invoice_id: int) -> dict:
    """{line id: its rest and its pieces in the stock} for a receipt's lines
    coded into pieces -- what its supplier's return may take back, by piece
    or as the rest (the owner, 18 Nov 2026). A line not coded is not here."""
    out = {}
    for line in InvoiceItem.query.filter_by(invoice_id=int(invoice_id)).order_by(InvoiceItem.id):
        pieces = line_pieces(line)
        if not pieces:
            continue
        out[line.id] = {'rest': max(line_rest(line), 0.0),
                        'pieces': [v for v in (piece_view(p) for p in pieces) if v['in_stock']]}
    return out


def pending_lines() -> list[dict]:
    """The station's list: posted receipt lines of categories tracked by the
    piece with weight left to code, oldest first."""
    rows = (InvoiceItem.query.join(Invoice, Invoice.id == InvoiceItem.invoice_id)
            .join(Category, Category.id == InvoiceItem.category_id)
            .filter(Invoice.is_posted.is_(True), Invoice.receiving_stage.in_(RECEIVED_STAGES),
                    Category.tracking == 'piece')
            .order_by(Invoice.date, InvoiceItem.id).all())
    views = [line_view(line) for line in rows]
    views += [coding_view(c) for c in StockCoding.query.order_by(StockCoding.id).all()]
    return [v for v in views if v['rest'] > GRAM]


# ── «ترميز من المخزون الموجود» (R3.5) ───────────────────────────────────────

def coding_view(batch: StockCoding) -> dict:
    """A batch as the station shows it, as a receipt line: its location for a
    supplier, its number for an invoice's."""
    category = db.session.get(Category, batch.category_id)
    safe = db.session.get(SafeBox, batch.safe_box_id)
    pieces = line_pieces(batch)
    coded = round(sum(float(p.weight or 0.0) for p in pieces), 3)
    return {'kind': 'stock', 'line_id': None, 'coding_id': batch.id, 'invoice_id': None,
            'invoice_number': f'ترميز مخزون #{batch.id}', 'stage': 'stock',
            'date': batch.created_at.isoformat() if batch.created_at else None,
            'supplier_name': None, 'safe_box_id': batch.safe_box_id, 'safe_name': getattr(safe, 'name', None),
            'category_id': batch.category_id, 'category_name': getattr(category, 'name', None),
            'karat': int(batch.karat), 'weight': round(float(batch.weight), 3),
            'size_system_id': getattr(category, 'size_system_id', None),
            'wage_per_gram': None, 'wage_by_piece': True, 'note': batch.note,
            'pieces': len(pieces), 'pieces_weight': coded, 'rest': round(float(batch.weight) - coded, 3)}


def reserved_grams(safe_box_id: int, karat: int, category_id: int) -> float:
    """What the open batches of a location's category have yet to code."""
    batches = StockCoding.query.filter_by(safe_box_id=safe_box_id, karat=karat, category_id=category_id).all()
    return round(sum(max(float(b.weight) - pieces_weight(b), 0.0) for b in batches), 3)


def open_coding(*, safe_box_id, category_id, weight, note=None, by: str, now) -> StockCoding:
    """A batch of a location's stock of a category to code -- or PieceRefused.
    Its weight no more than the location holds of it not yet pieced nor
    promised to an open batch. It takes no wage: each piece is written its
    own (ADR-096 §4)."""
    from services.receiving import coding_on
    if not coding_on(now):
        raise PieceRefused('coding_not_open', 'الترميز من المخزون الموجود لم يُفتح: يفتحه المدير من الإعدادات')
    try:
        safe = db.session.get(SafeBox, int(safe_box_id))
        category = db.session.get(Category, int(category_id))
    except (TypeError, ValueError):
        safe = category = None
    # an office's deposit is its gold held for it, not ours to code (ADR-052)
    if safe is None or getattr(safe, 'stock_location', None) in (None, '', 'deposit'):
        raise PieceRefused('coding_location_invalid', 'اختر خزينة مخزون')
    if category is None or category.is_active is False or (category.tracking or 'weight') != 'piece':
        raise PieceRefused('piece_category_by_weight', 'التصنيف غير موجود أو موقوف أو يُتابَع بالوزن')
    try:
        weight = round(float(weight), 3)
    except (TypeError, ValueError):
        raise PieceRefused('coding_figures_invalid', 'وزن الدفعة مطلوب') from None
    if weight <= GRAM:
        raise PieceRefused('coding_figures_invalid', 'وزن الدفعة أكبر من صفر')
    karat = int(round(float(category.karat or 0)))
    room = round(free_grams(safe, karat, category.id) - reserved_grams(safe.id, karat, category.id), 3)
    if weight > room + GRAM:
        raise PieceRefused('coding_more_than_held',
                           f'في «{safe.name}» من «{category.name}» خارج الاستلامات وبلا ترميز '
                           f'{max(room, 0.0):.2f} جم فقط')
    batch = StockCoding(safe_box_id=safe.id, category_id=category.id, karat=karat, weight=weight,
                        note=(str(note).strip()[:200] or None) if note else None,
                        created_at=now, created_by=by)
    db.session.add(batch)
    db.session.flush()
    return batch


# ── a piece moves with the voucher that names it (R3.6) ─────────────────────

def piece_location(piece: Item):
    """The stock safe holding the piece: its allocations' net, by account."""
    from accounting.balances import counted_line_filters
    rows = (db.session.query(JournalEntryLine.account_id, func.sum(StockLineAllocation.grams))
            .join(StockLineAllocation, StockLineAllocation.journal_entry_line_id == JournalEntryLine.id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(StockLineAllocation.item_id == piece.id, *counted_line_filters())
            .group_by(JournalEntryLine.account_id).all())
    held = [account_id for account_id, grams in rows if float(grams or 0.0) > GRAM]
    return SafeBox.query.filter_by(account_id=held[0]).first() if len(held) == 1 else None


def _piece_by_ref(ref):
    if isinstance(ref, int) or (isinstance(ref, str) and ref.strip().isdigit()):
        return db.session.get(Item, int(ref))
    return Item.query.filter_by(item_code=str(ref or '').strip().upper()).first()


def pieces_grams_at(safe_box: SafeBox, karat: int) -> float:
    """The grams of the pieces a location holds in a karat -- pieces only: a
    catalogue item of before (I-) names its allocations too, and is not one."""
    from sqlalchemy import or_
    from accounting.balances import counted_line_filters
    grams = (db.session.query(func.coalesce(func.sum(StockLineAllocation.grams), 0.0))
             .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .join(Item, Item.id == StockLineAllocation.item_id)
             .filter(JournalEntryLine.account_id == safe_box.account_id, StockLineAllocation.karat == int(karat),
                     or_(Item.receipt_item_id.isnot(None), Item.coding_id.isnot(None)), *counted_line_filters())
             .scalar())
    return round(float(grams or 0.0), 3)


def refuse_piece_transfer(from_safe: SafeBox, to_safe: SafeBox, refs, weights: dict, held: dict = None) -> list:
    """The pieces a transfer names -- or PieceRefused: each a piece, named
    once, in the stock and in the source; into a stock location that is not
    an office's deposit; each karat's weight at least its pieces'. And what
    stays in the source of a karat (*held*, its balance, less what moves)
    covers the pieces left there: pieces moved unnamed would stay «in» a
    location their gold has left."""
    pieces, seen = [], set()
    for ref in refs or []:
        piece = _piece_by_ref(ref)
        if not is_piece(piece):
            raise PieceRefused('piece_unknown', f'لا قطعة بالرقم {ref}')
        if piece.id in seen:
            raise PieceRefused('piece_named_twice', f'القطعة {piece.item_code} مذكورة مرتين')
        seen.add(piece.id)
        if piece_held(piece.id) <= GRAM:
            raise PieceRefused('piece_sold', f'القطعة {piece.item_code} ليست في المخزون')
        where = piece_location(piece)
        if where is None or where.id != from_safe.id:
            raise PieceRefused('piece_not_here', f'القطعة {piece.item_code} ليست في «{from_safe.name}»'
                                                 + (f' بل في «{where.name}»' if where is not None else ''))
        pieces.append(piece)
    if pieces and getattr(to_safe, 'stock_location', None) in (None, '', 'deposit'):
        raise PieceRefused('piece_destination_invalid', 'القطعة تُنقل إلى خزينة مخزون، لا إلى وديعة مكتب')
    by_karat = {}
    for piece in pieces:
        k = int(round(float(piece.karat)))
        by_karat[k] = round(by_karat.get(k, 0.0) + float(piece.weight), 3)
    for karat, grams in by_karat.items():
        if grams > float(weights.get(karat) or 0.0) + GRAM:
            raise PieceRefused('transfer_lighter_than_pieces',
                               f'وزن عيار {karat} في السند أقل من قطعه ({grams:.2f} جم)')
    for karat, moving in (weights or {}).items():
        moving = float(moving or 0.0)
        if held is None or moving <= GRAM:
            continue
        staying = round(float(held.get(karat) or 0.0) - moving, 3)
        left = round(pieces_grams_at(from_safe, karat) - by_karat.get(karat, 0.0), 3)
        if left > staying + GRAM:
            raise PieceRefused('pieces_left_unnamed',
                               f'يبقى في «{from_safe.name}» من عيار {karat} {max(staying, 0.0):.2f} جم '
                               f'وفيه قطع {left:.2f} جم: سمِّ القطع المنقولة')
    return pieces


def carry_pieces(entry, from_safe: SafeBox, to_safe: SafeBox, pieces, *, now, by, what: str) -> list:
    """Each piece's share out of the source's line and into the target's,
    under its number -- the allocation's one rule (spread)."""
    from services.stock_ledger import spread
    lines = (JournalEntryLine.query.filter_by(journal_entry_id=entry.id, is_deleted=False)
             .order_by(JournalEntryLine.id).all())
    written = []
    for piece in pieces:
        karat = int(round(float(piece.karat)))
        part = [(piece.category_id, piece.id, round(float(piece.weight), 3))]
        for safe in (from_safe, to_safe):
            written += spread([l for l in lines if l.account_id == safe.account_id], karat, part,
                              now=now, by=by, what=what)
    return written



# ── its RFID tag (R3.7, §7; ADR-085 law 2; law 6) ────────────────────────────

EPC_PREFIX = '4B4A'          # «KJ» in ASCII hexadecimal
TECHNOLOGIES = ('uhf_epc96',)


def epc_of(number: str) -> str:
    """A number's tag value: 4B4A, then its digits padded to twenty -- 24
    hexadecimal characters (EPC-96)."""
    digits = ''.join(ch for ch in str(number) if ch.isdigit())
    return f'{EPC_PREFIX}{int(digits):020d}'


def number_of_epc(value: str):
    """The number a value of ours says -- None for another's."""
    value = str(value or '').strip().upper()
    if len(value) != 24 or not value.startswith(EPC_PREFIX) or not value[4:].isdigit():
        return None
    return f'KJ-{int(value[4:]):06d}'


def _valid_epc96(value: str) -> bool:
    return len(value) == 24 and all(ch in '0123456789ABCDEF' for ch in value)


def active_tag(piece: Item):
    return PieceTag.query.filter_by(item_id=piece.id, stopped_at=None).first()


def piece_by_tag(value: str):
    """The piece whose active tag a reader read."""
    tag = PieceTag.query.filter_by(value=str(value or '').strip().upper(), stopped_at=None).first()
    return db.session.get(Item, tag.item_id) if tag is not None else None


def mount_tag(piece: Item, *, value=None, technology='uhf_epc96', by: str, now) -> PieceTag:
    """A tag on a piece -- or PieceRefused: one active a piece; an active
    value never another's (law 6); EPC-96, 24 hexadecimal characters."""
    if not is_piece(piece):
        raise PieceRefused('piece_unknown', 'الرقاقة تُركَّب على قطعة مرمَّزة')
    if technology not in TECHNOLOGIES:
        raise PieceRefused('tag_value_invalid', f'تقنية الرقاقة غير معروفة: {technology}')
    value = str(value).strip().upper() if value else epc_of(piece.item_code)
    if not _valid_epc96(value):
        raise PieceRefused('tag_value_invalid', 'رمز الرقاقة 24 خانة ست عشرية (EPC-96)')
    if active_tag(piece) is not None:
        raise PieceRefused('piece_has_active_tag', f'للقطعة {piece.item_code} رقاقة نشطة: استبدلها إن تلفت')
    other = PieceTag.query.filter_by(value=value, stopped_at=None).first()
    if other is not None:
        raise PieceRefused('tag_in_use', f'الرمز {value} على رقاقة نشطة لقطعة أخرى')
    tag = PieceTag(item_id=piece.id, value=value, technology=technology, mounted_at=now, mounted_by=by)
    db.session.add(tag)
    db.session.flush()
    return tag


def replace_tag(piece: Item, *, reason, value=None, by: str, now) -> PieceTag:
    """A damaged tag stopped with its reason, a new one mounted; the piece and
    its number as they were."""
    reason = str(reason or '').strip()
    if not reason:
        raise PieceRefused('tag_reason_required', 'اذكر سبب استبدال الرقاقة')
    old = active_tag(piece)
    if old is not None:
        old.stopped_at, old.stopped_by, old.stop_reason = now, by, reason[:200]
        db.session.flush()
    return mount_tag(piece, value=value, technology=old.technology if old is not None else 'uhf_epc96',
                     by=by, now=now)


# ── the pieces' list (the owner, 16 Nov 2026) ───────────────────────────────

PIECE_STATES = ('in_stock', 'sold', 'returned_to_supplier', 'out')
PIECE_SORTS = {'number': Item.item_code, 'weight': Item.weight, 'name': Item.name}
PIECES_PER_PAGE_MAX = 100


class PiecesFilterInvalid(ValueError):
    """A filter, a sort or a page the list does not know."""


def _held_by_piece() -> dict:
    """{piece id: {account id: grams}} -- every piece's allocations on counted
    lines, net by account, in one reading."""
    from accounting.balances import counted_line_filters
    rows = (db.session.query(StockLineAllocation.item_id, JournalEntryLine.account_id,
                             func.sum(StockLineAllocation.grams))
            .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(StockLineAllocation.item_id.isnot(None), *counted_line_filters())
            .group_by(StockLineAllocation.item_id, JournalEntryLine.account_id).all())
    held: dict = {}
    for item_id, account_id, grams in rows:
        held.setdefault(item_id, {})[account_id] = float(grams or 0.0)
    return held


def stock_pieces(category_id=None) -> list:
    """[(piece, its safe box or None)] -- the pieces in stock, of a category or
    all: their allocations hold more than nothing (the list's reading), their
    place the one stock safe that holds them."""
    held = _held_by_piece()
    query = Item.query.filter((Item.receipt_item_id.isnot(None)) | (Item.coding_id.isnot(None)))
    if category_id is not None:
        query = query.filter(Item.category_id == int(category_id))
    account_of_safe = {s.account_id: s for s in SafeBox.query.filter(SafeBox.account_id.isnot(None))}
    found = []
    for piece in query.all():
        accounts = {a: g for a, g in held.get(piece.id, {}).items() if g > GRAM}
        if sum(held.get(piece.id, {}).values()) <= GRAM:
            continue
        found.append((piece, account_of_safe.get(next(iter(accounts))) if len(accounts) == 1 else None))
    return found


def _last_exits(item_ids) -> dict:
    """{piece id: (day, state)} -- the document that last took each piece out:
    a sale, a return to its supplier, or anything else (out)."""
    from accounting.balances import counted_line_filters
    if not item_ids:
        return {}
    rows = (db.session.query(StockLineAllocation.item_id, JournalEntry.date, JournalEntry.reference_type,
                             JournalEntry.reference_id)
            .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(StockLineAllocation.item_id.in_(list(item_ids)), StockLineAllocation.grams < -GRAM,
                    *counted_line_filters())
            .order_by(JournalEntry.date, StockLineAllocation.id).all())
    last = {item_id: (when, ref_type, ref_id) for item_id, when, ref_type, ref_id in rows}
    invoice_ids = {ref_id for _, ref_type, ref_id in last.values() if ref_type == 'invoice' and ref_id}
    kinds = dict(db.session.query(Invoice.id, Invoice.invoice_type).filter(Invoice.id.in_(invoice_ids)).all()
                 if invoice_ids else [])
    state_of = {'بيع': 'sold', 'مرتجع شراء (مورد)': 'returned_to_supplier'}
    return {item_id: (when, state_of.get(kinds.get(ref_id) if ref_type == 'invoice' else None, 'out'))
            for item_id, (when, ref_type, ref_id) in last.items()}


def _received_view(piece: Item) -> dict | None:
    """Where the piece was born: its receipt (date, document, supplier) or its batch of stock."""
    from models import Supplier
    source = piece_source(piece)
    if isinstance(source, StockCoding):
        safe = db.session.get(SafeBox, source.safe_box_id)
        return {'kind': 'coding', 'date': source.created_at.date().isoformat() if source.created_at else None,
                'document': None, 'invoice_id': None, 'supplier_name': None,
                'safe_name': getattr(safe, 'name', None)}
    if isinstance(source, InvoiceItem):
        invoice = db.session.get(Invoice, source.invoice_id)
        supplier = db.session.get(Supplier, invoice.supplier_id) if invoice and invoice.supplier_id else None
        return {'kind': 'receipt', 'date': invoice.date.date().isoformat() if invoice and invoice.date else None,
                'document': getattr(invoice, 'invoice_number', None), 'invoice_id': source.invoice_id,
                'supplier_name': getattr(supplier, 'name', None)}
    return None


NO_MODEL = 'none'      # the filter for the pieces with no model -- or no size (ADR-093 §4)


def pieces_list(*, q=None, category_id=None, karat=None, safe_box_id=None, model_id=None, size_id=None,
                state='in_stock', sort='number', descending=True, page=1, per_page=25, today) -> dict:
    """The pieces -- searched by number, name or a tag read; filtered by
    category, karat, place and state ('all' for every state); sorted and
    paged -- each with its place, state and receipt; and the shop's summary,
    whatever the filter. *today*: the caller's clock (ADR-015)."""
    if state not in PIECE_STATES + ('all',):
        raise PiecesFilterInvalid(f'حالة غير معروفة: {state}')
    if sort not in PIECE_SORTS:
        raise PiecesFilterInvalid(f'ترتيب غير معروف: {sort}')
    try:
        page, per_page = int(page), int(per_page)
    except (TypeError, ValueError):
        raise PiecesFilterInvalid('الصفحة وعدد القطع فيها أرقام') from None
    if page < 1 or not 1 <= per_page <= PIECES_PER_PAGE_MAX:
        raise PiecesFilterInvalid(f'الصفحة من 1، والقطع فيها من 1 إلى {PIECES_PER_PAGE_MAX}')

    query = Item.query.filter((Item.receipt_item_id.isnot(None)) | (Item.coding_id.isnot(None)))
    if category_id is not None:
        query = query.filter(Item.category_id == int(category_id))
    if karat is not None:
        query = query.filter(Item.karat == str(int(karat)))
    for column, value in ((Item.model_id, model_id), (Item.size_id, size_id)):
        if value in (None, ''):
            continue
        if str(value) == NO_MODEL:
            query = query.filter(column.is_(None))
        else:
            try:
                query = query.filter(column == int(value))
            except (TypeError, ValueError):
                raise PiecesFilterInvalid('الموديل والمقاس رقمان، أو «none» لما ليس له') from None
    text = str(q or '').strip()
    if text:
        tagged = db.session.query(PieceTag.item_id).filter(PieceTag.value == text.upper(),
                                                           PieceTag.stopped_at.is_(None))
        query = query.filter(Item.item_code.ilike(f'%{text}%') | Item.name.ilike(f'%{text}%')
                             | Item.id.in_(tagged))
    every = query.all()

    held = _held_by_piece()
    every_piece = Item.query.filter((Item.receipt_item_id.isnot(None)) | (Item.coding_id.isnot(None))).all()
    in_stock = {p.id for p in every_piece if sum(held.get(p.id, {}).values()) > GRAM}
    exits = _last_exits([p.id for p in every_piece if p.id not in in_stock])
    account_of_safe = {s.account_id: s for s in SafeBox.query.filter(SafeBox.account_id.isnot(None))}

    def state_of(piece):
        return 'in_stock' if piece.id in in_stock else exits.get(piece.id, (None, 'out'))[1]

    def place_of(piece):
        if piece.id not in in_stock:
            return None
        accounts = [a for a, grams in held.get(piece.id, {}).items() if grams > GRAM]
        return account_of_safe.get(accounts[0]) if len(accounts) == 1 else None

    chosen = [p for p in every if state == 'all' or state_of(p) == state]
    if safe_box_id is not None:
        chosen = [p for p in chosen if (place_of(p) is not None and place_of(p).id == int(safe_box_id))]
    key = {'number': lambda p: p.item_code or '', 'weight': lambda p: float(p.weight or 0.0),
           'name': lambda p: (p.name or '', p.item_code or '')}[sort]
    chosen.sort(key=key, reverse=bool(descending))
    shown = chosen[(page - 1) * per_page: page * per_page]

    rows = []
    for piece in shown:
        view = piece_view(piece)
        where = place_of(piece)
        left = exits.get(piece.id) if piece.id not in in_stock else None
        category = db.session.get(Category, piece.category_id) if piece.category_id else None
        view.update({'state': state_of(piece), 'in_stock': piece.id in in_stock,
                     'location': {'id': where.id, 'name': where.name} if where is not None else None,
                     'left_at': left[0].date().isoformat() if left and left[0] else None,
                     'category_id': piece.category_id, 'category_name': getattr(category, 'name', None),
                     'description': piece.description, 'received': _received_view(piece)})
        rows.append(view)

    tagged_now = {i for (i,) in db.session.query(PieceTag.item_id).filter(PieceTag.stopped_at.is_(None))}
    month = today.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    weights = {p.id: float(p.weight or 0.0) for p in every_piece}
    summary = {
        'in_stock_count': len(in_stock),
        'in_stock_weight': round(sum(weights[i] for i in in_stock), 3),
        'in_stock_untagged': len(in_stock - tagged_now),
        'sold_this_month': sum(1 for when, kind in exits.values() if kind == 'sold' and when and when >= month),
    }
    return {'pieces': rows, 'total': len(chosen), 'page': page, 'per_page': per_page, 'summary': summary}
