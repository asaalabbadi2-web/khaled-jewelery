"""A return's lines are its original invoice's lines coming back.

What a line carries about the goods -- its category -- is the original line's,
not what the return screen happened to send. The screen sends the original
line's id (original_invoice_item_id) and no category, so every sale return was
saved uncategorised: the gold went back to the inventory ledger's no-category
bucket, no category-weight movement was written, and the categories it came
from stayed short (946, 1032, 1035, 1089, 3300; measured on the 10 Oct 2026 copy).
"""
from __future__ import annotations

from models import InvoiceItem


def _key(name, karat):
    try:
        k = float(karat or 0)
    except (TypeError, ValueError):
        k = 0.0
    return (str(name or '').strip(), k)


def inherit_original_categories(items: list, original_invoice_id: int) -> None:
    """Fill each line's missing category_id from the original invoice's line.

    Matched by original_invoice_item_id; a line without it, by name and karat,
    each original line used once. A category the request sends is kept.
    """
    originals = InvoiceItem.query.filter_by(invoice_id=original_invoice_id).order_by(InvoiceItem.id).all()
    if not originals:
        return
    by_id = {o.id: o for o in originals}
    unused = list(originals)
    for line in items:
        if not isinstance(line, dict) or line.get('category_id'):
            continue
        match = None
        try:
            match = by_id.get(int(line.get('original_invoice_item_id') or 0))
        except (TypeError, ValueError):
            match = None
        if match is None:
            key = _key(line.get('name'), line.get('karat'))
            match = next((o for o in unused if _key(o.name, o.karat) == key), None)
        if match is None:
            continue
        if match in unused:
            unused.remove(match)
        if match.category_id:
            line['category_id'] = int(match.category_id)


def sale_return_cost(ret) -> float | None:
    """What a sale return's gold cost: its original sale's cost, in the share it
    returns -- not the price the return screen sent as its cost (every sale
    return carried its own price as its cost: 3300 1,200.00 against 925.23;
    the owner, 10 Oct 2026). None when the original carries no cost."""
    from models import Invoice, db
    from points.engine import returned_share
    from services.gold_cost_postings import posted_sale_cost
    original = db.session.get(Invoice, int(ret.original_invoice_id)) if ret.original_invoice_id else None
    if original is None:
        return None
    # The cost its sale posted (ADR-042 phase 3), else the sale's recorded cost.
    posted = posted_sale_cost(original)
    cost = sum(posted.values()) if posted else float(original.total_cost or 0.0)
    if not cost:
        return None
    return round(cost * returned_share(ret, original), 2)


def purchase_gold_safe_id(original_invoice_id: int) -> int | None:
    """The gold safe a customer purchase's posted entry put its gold in -- where
    its return gives the gold back from (the owner, 21 Oct 2026: «يخرج من العهدة
    التي دخلها؛ حتى وإن سُحب الذهب منها يُعاد إليها بتحويل»). Read from the
    books, not from who makes the return. None when the purchase put none in a
    gold safe."""
    from models import JournalEntry, JournalEntryLine, SafeBox, db
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=original_invoice_id,
                                                         is_deleted=False).all()]
    safes = {int(a): int(s) for s, a in db.session.query(SafeBox.id, SafeBox.account_id)
             .filter(SafeBox.safe_type == 'gold').all()}
    grams: dict[int, float] = {}
    for l in JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries or [-1]),
                                           JournalEntryLine.account_id.in_(list(safes) or [-1]),
                                           JournalEntryLine.is_deleted.is_(False)).all():
        g = sum((float(getattr(l, f'debit_{k}k') or 0) - float(getattr(l, f'credit_{k}k') or 0)) * k
                for k in (18, 21, 22, 24))
        grams[safes[l.account_id]] = grams.get(safes[l.account_id], 0.0) + g
    filled = {s: g for s, g in grams.items() if g > 0}
    return max(filled, key=filled.get) if filled else None


def invoice_gold_safe_id(invoice_id: int) -> int | None:
    """The gold safe an invoice's posted entry moved the most gold in or out
    of -- a purchase's that it filled, a sale's that it took from: where a
    correction of its line starts (ADR-056)."""
    from models import JournalEntry, JournalEntryLine, SafeBox, db
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id,
                                                         is_deleted=False).all()]
    safes = {int(a): int(s) for s, a in db.session.query(SafeBox.id, SafeBox.account_id)
             .filter(SafeBox.safe_type == 'gold', SafeBox.stock_location.isnot(None)).all()}
    moved: dict[int, float] = {}
    for l in JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries or [-1]),
                                           JournalEntryLine.account_id.in_(list(safes) or [-1]),
                                           JournalEntryLine.is_deleted.is_(False)).all():
        g = sum((float(getattr(l, f'debit_{k}k') or 0) - float(getattr(l, f'credit_{k}k') or 0)) * k
                for k in (18, 21, 22, 24))
        moved[safes[l.account_id]] = moved.get(safes[l.account_id], 0.0) + g
    moved = {s: abs(g) for s, g in moved.items() if abs(g) > 1e-9}
    return max(moved, key=moved.get) if moved else None


# ── What remains of a line (the return audit, 11 Nov 2026) ─────────────────
#
# A return gives back of each original line no more than remains of it: its
# grams and its pieces, less every return before that was not rejected. The
# return's line keeps the line it returns (invoice_item.original_invoice_item_id);
# it was checked when saved and thrown away, so a line was returned whole three
# times (3779 on the 10 Nov copy). A line's weight is the whole line's
# (add_invoice: «لا نضربه في الكمية»), but 68 sales of Mar-Apr 2026 kept a
# piece's -- their invoice weight is their lines' by their counts -- and are
# read so.

RETURN_TYPES = ('مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)')
CUSTOMER_RETURNS = ('مرتجع بيع', 'مرتجع شراء')
GRAM = 0.001


class ReturnRefused(ValueError):
    """A return the law refuses, said by its code and in the owner's words."""

    def __init__(self, code: str, message: str, **detail):
        super().__init__(message)
        self.code, self.message, self.detail = code, message, detail


def _f(value) -> float:
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def keeps_a_piece_s_weight(invoice) -> bool:
    """A sale of Mar-Apr 2026: its lines' weight a piece's, its invoice weight
    theirs by their counts -- and not their sum."""
    lines = list(invoice.items or [])
    if not any(int(l.quantity or 1) > 1 for l in lines):
        return False
    total = _f(invoice.total_weight)
    by_count = sum(_f(l.weight) * max(int(l.quantity or 1), 1) for l in lines)
    summed = sum(_f(l.weight) for l in lines)
    return abs(total - by_count) < 0.01 and abs(total - summed) >= 0.01


def line_grams(line, piece_weights: bool) -> float:
    """The grams a line holds: its weight, by its count where it kept a piece's."""
    return _f(line.weight) * (max(int(line.quantity or 1), 1) if piece_weights else 1)


def returned_of_lines(original, *, but=None) -> dict:
    """{original line id: (grams, pieces, amount)} its returns gave back --
    every return of it not rejected, by the lines that keep their line."""
    from models import Invoice
    returns = Invoice.query.filter(Invoice.original_invoice_id == original.id,
                                   Invoice.invoice_type.in_(RETURN_TYPES))
    out: dict = {}
    for ret in returns.all():
        if ret.id == but or (ret.status or '') == 'rejected':
            continue
        for line in ret.items or []:
            if line.original_invoice_item_id is None:
                continue
            grams, pieces, amount = out.get(line.original_invoice_item_id, (0.0, 0, 0.0))
            out[line.original_invoice_item_id] = (grams + _f(line.weight),
                                                  pieces + max(int(line.quantity or 1), 1),
                                                  amount + _f(line.price))
    return out


def refuse_return_lines(original, invoice_type: str, items: list) -> None:
    """A return of *original* sending *items*, or ReturnRefused: a customer's
    return needs a posted original; each line names a line of it; and of each
    line no more grams or pieces than remain. Raised on any fault in the check
    itself too -- a return is never saved past a check that did not run."""
    if invoice_type in CUSTOMER_RETURNS and (not original.is_posted or (original.status or '') == 'rejected'):
        raise ReturnRefused('original_not_posted',
                            'الفاتورة الأصلية غير مرحّلة أو مرفوضة: لا تُرجَع، تُعدَّل أو تُحذف')
    if not isinstance(items, list):
        raise ReturnRefused('items_not_a_list', 'أسطر المرتجع غير صالحة')
    originals = {l.id: l for l in (original.items or [])}
    asked: dict = {}
    for n, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            continue
        raw = item.get('original_invoice_item_id')
        if raw in (None, '', False):
            raise ReturnRefused('missing_original_invoice_item_id',
                                'يجب ربط كل صنف مرتجع بصنف من الفاتورة الأصلية', line_index=n)
        try:
            line_id = int(raw)
        except (TypeError, ValueError):
            raise ReturnRefused('invalid_original_invoice_item_id', 'رقم سطر الفاتورة الأصلية غير صحيح',
                                line_index=n, value=raw)
        if line_id not in originals:
            raise ReturnRefused('original_invoice_item_not_found',
                                'أحد أصناف المرتجع غير موجود ضمن الفاتورة الأصلية',
                                original_invoice_item_id=line_id, original_invoice_id=original.id)
        weight = abs(_f(item.get('weight', item.get('total_weight'))))
        price = abs(_f(item.get('price', item.get('net'))))
        # A line of no weight and no price says nothing came back (3395 carried
        # one beside its real line; the owner, 11 Nov 2026: «يرفض»).
        if weight <= GRAM and price <= 0.005:
            raise ReturnRefused('return_line_empty',
                                f'السطر {n} بلا وزن ولا قيمة: يُحذف من المرتجع', line_index=n)
        grams, pieces = asked.get(line_id, (0.0, 0))
        asked[line_id] = (grams + weight, pieces + abs(int(_f(item.get('quantity', 1)) or 1)))
    piece_weights = keeps_a_piece_s_weight(original)
    # A customer's return gives gold back: money back with none is a correction
    # -- «تصحيح فاتورة» (3399, 3442; the owner, 11 Nov 2026: «يرفض»). Where the
    # lines it names weighed nothing themselves, none is asked.
    if invoice_type in CUSTOMER_RETURNS and asked:
        weighed_lines = [i for i in asked if line_grams(originals[i], piece_weights) > GRAM]
        if weighed_lines and sum(asked[i][0] for i in weighed_lines) <= GRAM:
            raise ReturnRefused('return_without_gold',
                                'مرتجع بلا ذهب: تصحيح المبلغ أو العيار أو الوزن يكون بـ«تصحيح فاتورة» لا بالمرتجع')
    before = returned_of_lines(original)
    for line_id, (grams, pieces) in asked.items():
        line = originals[line_id]
        given_grams, given_pieces, _ = before.get(line_id, (0.0, 0, 0.0))
        sold_grams = line_grams(line, piece_weights)
        sold_pieces = max(int(line.quantity or 1), 1)
        left_grams = round(max(sold_grams - given_grams, 0.0), 3)
        left_pieces = max(sold_pieces - given_pieces, 0)
        if pieces > sold_pieces:
            raise ReturnRefused('return_quantity_exceeds_original',
                                f'«{line.name}»: بيع منه {sold_pieces} قطعة، والمطلوب {pieces}',
                                line=line.name, original_invoice_item_id=line_id,
                                original_quantity=sold_pieces, returned_quantity=pieces)
        # A weighed line's gold is held by its grams; its pieces say what came
        # back, and a line comes back in parts of its weight (RETURN-LIMIT-1, the
        # owner 8 Oct 2026) -- the screen sends the line's count with each part.
        # The pieces are counted across returns only where there is no weight.
        weighed = sold_grams > GRAM
        if (weighed and grams > left_grams + GRAM) or (not weighed and pieces > left_pieces):
            raise ReturnRefused(
                'return_line_exceeds_remaining',
                f'«{line.name}»: الباقي منه {left_grams:.3f} جم و{left_pieces} قطعة، '
                f'والمطلوب {grams:.3f} جم و{pieces} قطعة',
                line=line.name, original_invoice_item_id=line_id,
                sold_grams=round(sold_grams, 3), returned_grams=round(given_grams, 3), remaining_grams=left_grams,
                sold_pieces=sold_pieces, remaining_pieces=left_pieces,
                requested_grams=round(grams, 3), requested_pieces=pieces)



# ── What a line comes back for (the owner, 11 Nov 2026) ─────────────────────
#
# «الوزن والمبلغ المرتجع يكتب يدويا فلا يحكم مبلغ السطر الاصلي سعر المرتجع»:
# a returned line's amount is typed with its weight. Of a line, across its
# returns, no more than it sold for («نعم»); a return's total is its lines';
# what is paid back no more than the return is worth (and than was paid,
# add_invoice's RETURN-OWED-1). Its cost and points follow its weight, its VAT
# its original's as posted (ADR-043).


def _line_base(line) -> float:
    net, tax = _f(line.net), _f(line.tax)
    return (net + tax) if (net or tax) else _f(line.price)


def line_values(original) -> dict:
    """{line id: what it sold for}: its net and VAT (else its price) -- in its
    share of its invoice's total where its lines do not add up to it (110
    sales of Jan-Mar 2026 by price or by net, e.g. 424: lines of 2,540 on 12,700)."""
    lines = list(original.items or [])
    bases = {l.id: _line_base(l) for l in lines}
    summed = sum(bases.values())
    total = _f(original.total)
    scale = total / summed if summed > 0 and total > 0 and abs(total - summed) > 0.01 else 1.0
    return {i: round(b * scale, 2) for i, b in bases.items()}


def line_scale(original) -> float:
    """By how much its lines' own figures are scaled to their values (1 where they add up)."""
    summed = sum(_line_base(l) for l in (original.items or []))
    total = _f(original.total)
    return total / summed if summed > 0 and total > 0 and abs(total - summed) > 0.01 else 1.0


def refuse_return_amounts(original, invoice_type: str, items: list, total, refund: list) -> None:
    """A customer's return's amounts, or ReturnRefused: every line its amount;
    of a line no more than it sold for across its returns; the total its lines';
    what is paid back no more than the return is worth."""
    if invoice_type not in CUSTOMER_RETURNS:
        return
    values = line_values(original)
    before = returned_of_lines(original)
    asked: dict = {}
    names = {l.id: l.name for l in (original.items or [])}
    lines_total = 0.0
    for n, item in enumerate(items or [], start=1):
        if not isinstance(item, dict):
            continue
        line_id = int(item.get('original_invoice_item_id'))
        price = _f(item.get('price'))
        if price <= 0.005:
            raise ReturnRefused('return_line_unpriced',
                                f'السطر {n} بلا مبلغ: اكتب ما يُردّ عنه', line_index=n)
        asked[line_id] = asked.get(line_id, 0.0) + price
        lines_total += price
    for line_id, amount in asked.items():
        given = before.get(line_id, (0.0, 0, 0.0))[2]
        left = round(max(values.get(line_id, 0.0) - given, 0.0), 2)
        if amount > left + 0.01:
            raise ReturnRefused(
                'return_line_amount_exceeds_original',
                f'«{names.get(line_id)}»: بيع بـ{values.get(line_id, 0.0):,.2f}، والباقي منه {left:,.2f}، '
                f'والمطلوب {amount:,.2f}',
                line=names.get(line_id), original_invoice_item_id=line_id, sold_amount=values.get(line_id, 0.0),
                returned_amount=round(given, 2), remaining_amount=left, requested_amount=round(amount, 2))
    total = _f(total)
    if abs(total - lines_total) > 0.01:
        raise ReturnRefused('return_total_not_its_lines',
                            f'إجمالي المرتجع {total:,.2f} وأسطره {lines_total:,.2f}: الإجمالي مجموع أسطره',
                            total=round(total, 2), lines_total=round(lines_total, 2))
    refund = sum(abs(_f(p.get('amount'))) for p in (refund or []) if isinstance(p, dict))
    if refund > lines_total + 0.01:
        raise ReturnRefused('return_refund_exceeds_return',
                            f'ما يُردّ نقدًا {refund:,.2f} أكثر من قيمة المرتجع {lines_total:,.2f}',
                            refund=round(refund, 2), total=round(lines_total, 2))


def return_lines_of(original) -> dict:
    """What a return of *original* may still give back, for the screen to build
    its lines from -- the same reading the save is checked by: each line's
    grams, pieces and amount sold, returned and remaining; and what may still
    be paid back in cash (what was paid, less what its returns paid back)."""
    from models import Invoice
    piece_weights = keeps_a_piece_s_weight(original)
    values = line_values(original)
    before = returned_of_lines(original)
    lines = []
    for line in original.items or []:
        sold_grams = round(line_grams(line, piece_weights), 3)
        sold_pieces = max(int(line.quantity or 1), 1)
        grams, pieces, amount = before.get(line.id, (0.0, 0, 0.0))
        lines.append({
            'id': line.id, 'name': line.name, 'karat': line.karat, 'category_id': line.category_id,
            'sold_grams': sold_grams, 'sold_pieces': sold_pieces, 'sold_amount': values.get(line.id, 0.0),
            'returned_grams': round(grams, 3), 'returned_amount': round(amount, 2),
            'remaining_grams': round(max(sold_grams - grams, 0.0), 3),
            'remaining_pieces': max(sold_pieces - pieces, 0) if sold_grams <= GRAM else sold_pieces,
            'remaining_amount': round(max(values.get(line.id, 0.0) - amount, 0.0), 2),
        })
    returns = [r for r in Invoice.query.filter(Invoice.original_invoice_id == original.id,
                                               Invoice.invoice_type.in_(RETURN_TYPES)).all()
               if (r.status or '') != 'rejected']
    paid_back = sum(_f(r.amount_paid) for r in returns)
    return {
        'invoice_id': original.id, 'lines': lines, 'returned_before': bool(returns),
        'refundable': round(max(_f(original.amount_paid) - paid_back, 0.0), 2),
    }
