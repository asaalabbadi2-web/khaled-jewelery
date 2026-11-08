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

from sqlalchemy import func

from models import (Category, Invoice, InvoiceItem, Item, JournalEntry, JournalEntryLine, PIECE_NUMBER,
                    SafeBox, StockCoding, StockLineAllocation, db)

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


def register_piece(source, *, weight, stones_weight=0.0, by: str, now, request_key=None) -> Item:
    """One piece under a posted receipt's line or a batch of stock -- or PieceRefused."""
    from services.stock_ledger import allocate

    source, category, karat = _source_of(source)
    batch = isinstance(source, StockCoding)
    if category is None or (category.tracking or 'weight') != 'piece':
        raise PieceRefused('piece_category_by_weight', 'تصنيف السطر يُتابَع بالوزن: لا تُسجَّل فيه قطع')
    try:
        weight = round(float(weight), 3)
        stones = round(float(stones_weight or 0.0), 3)
    except (TypeError, ValueError):
        raise PieceRefused('piece_weight_invalid', 'وزن القطعة غير مفهوم') from None
    if weight <= GRAM or stones < 0 or stones >= weight:
        raise PieceRefused('piece_weight_invalid', 'وزن القطعة أكبر من صفر، وفصوصها أقل منه')
    rest = round(float(source.weight or 0.0) - pieces_weight(source), 3)
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
    piece = Item(item_code=code, barcode=code, name=category.name, category_id=category.id, karat=str(karat),
                 weight=weight, has_stones=stones > GRAM, stones_weight=stones, price=0.0, stock=1, count=1,
                 receipt_item_id=None if batch else source.id, coding_id=source.id if batch else None,
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
    if not is_piece(item):
        return
    for fact in PIECE_FIXED:
        if fact in (data or {}) and not _same(fact, getattr(item, fact), data[fact]):
            raise PieceRefused('piece_fixed', f'لا يُعدَّل في القطعة {item.item_code} إلا اسمها ووصفها')


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


# ── the wage: read, never kept (§6) ──────────────────────────────────────────

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
    """The source's wage and its shares (law 5) -- or None while unknown. The
    wage is per gram, always (the owner, 9 Nov 2026): bullion's too -- its
    line's wage given whole is divided by its weight, one line per bar size.
    A receipt line's is its invoice's, unknown until it is completed; a
    batch's is entered by hand when it is opened (the owner, 9 Nov 2026)."""
    if isinstance(source, StockCoding):
        return _shares(source, float(source.wage_per_gram))
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
            'pieces': len(pieces), 'pieces_weight': coded, 'rest': round(float(line.weight or 0.0) - coded, 3)}


def piece_view(piece: Item) -> dict:
    wage = piece_wage(piece)
    return {'id': piece.id, 'item_code': piece.item_code, 'barcode': piece.barcode, 'name': piece.name,
            'karat': piece.karat, 'weight': round(float(piece.weight or 0.0), 3),
            'stones_weight': round(float(piece.stones_weight or 0.0), 3), 'line_id': piece.receipt_item_id,
            'coding_id': piece.coding_id,
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
            'wage_per_gram': float(batch.wage_per_gram), 'note': batch.note,
            'pieces': len(pieces), 'pieces_weight': coded, 'rest': round(float(batch.weight) - coded, 3)}


def reserved_grams(safe_box_id: int, karat: int, category_id: int) -> float:
    """What the open batches of a location's category have yet to code."""
    batches = StockCoding.query.filter_by(safe_box_id=safe_box_id, karat=karat, category_id=category_id).all()
    return round(sum(max(float(b.weight) - pieces_weight(b), 0.0) for b in batches), 3)


def open_coding(*, safe_box_id, category_id, weight, wage_per_gram, note=None, by: str, now) -> StockCoding:
    """A batch of a location's stock of a category to code -- or PieceRefused.
    Its weight no more than the location holds of it not yet pieced nor
    promised to an open batch; its wage per gram entered (zero is a wage,
    none is not)."""
    from services.receiving import receiving_on
    if not receiving_on(now):
        raise PieceRefused('coding_not_open', 'الترميز من المخزون يبدأ مع الاستلام (أول 2027)')
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
        wage = round(float(wage_per_gram), 6)
    except (TypeError, ValueError):
        raise PieceRefused('coding_figures_invalid', 'الوزن وأجرة الجرام مطلوبان') from None
    if weight <= GRAM or wage < 0:
        raise PieceRefused('coding_figures_invalid', 'الوزن أكبر من صفر، وأجرة الجرام صفر فأكثر')
    karat = int(round(float(category.karat or 0)))
    room = round(free_grams(safe, karat, category.id) - reserved_grams(safe.id, karat, category.id), 3)
    if weight > room + GRAM:
        raise PieceRefused('coding_more_than_held',
                           f'في «{safe.name}» من «{category.name}» خارج الاستلامات وبلا ترميز '
                           f'{max(room, 0.0):.2f} جم فقط')
    batch = StockCoding(safe_box_id=safe.id, category_id=category.id, karat=karat, weight=weight,
                        wage_per_gram=wage, note=(str(note).strip()[:200] or None) if note else None,
                        created_at=now, created_by=by)
    db.session.add(batch)
    db.session.flush()
    return batch
