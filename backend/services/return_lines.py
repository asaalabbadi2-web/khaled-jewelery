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
