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
