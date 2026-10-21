"""A supplier purchase's stones: counted as gold, or priced by the carat (ت4).

The owner (21 Oct 2026): gold is net in every screen, its stones beside it; at
the supplier «بعض الأحجار تُحسب بسعر القيراط وبعضها تُحسب كذهب». Stones
counted as gold stay in the line's gold (in at the standing weight, out to the
customer at the standing weight -- as the shop has always posted them). Stones
priced by the carat leave the gold -- the line's gold is its standing weight
less their weight -- and their value is owed in riyals, with VAT as the wages
take it (the owner's choice), on the role «مخزون الأحجار».

normalize() is the one rule, applied to the request before anything reads its
weights: a priced line's `weight` becomes its gold, its `standing_weight` the
weight as sent, and the supplier's gold is recomputed from the lines (the
screen sent its own copy, from the standing weights).
"""
from __future__ import annotations

KINDS = ('as_gold', 'priced')
SUPPLIER_PURCHASE, SUPPLIER_RETURN = 'شراء', 'مرتجع شراء (مورد)'
TOLERANCE = 0.0005
CENT = 0.01


class StonesRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _f(value) -> float:
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def normalize(invoice_type: str, data: dict) -> float:
    """The priced stones' value in riyals (0 when none), the request's lines
    set to their gold -- or StonesRefused."""
    if invoice_type not in (SUPPLIER_PURCHASE, SUPPLIER_RETURN):
        return 0.0
    items = data.get('items') or []
    priced_value = 0.0
    any_priced = False
    for n, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            continue
        if invoice_type == SUPPLIER_RETURN and item.get('original_invoice_item_id'):
            # The return screen loads its original's lines without their
            # stones: the gold would come back and their riyals stay owed.
            from models import InvoiceItem, db
            try:
                original = db.session.get(InvoiceItem, int(item['original_invoice_item_id']))
            except (TypeError, ValueError):
                original = None
            if original is not None and original.stones_kind == 'priced':
                raise StonesRefused('priced_stones_return_not_built',
                                    f'السطر {n}: مرتجع الأحجار المسعَّرة لم يُبنَ بعد — يُرتجع بفاتورة شراء معكوسة يدويًّا')
        stones = _f(item.get('stones_weight'))
        kind = item.get('stones_kind')
        if stones <= TOLERANCE and not kind:
            continue
        kind = kind or 'as_gold'                       # today's practice: counted as gold
        if kind not in KINDS:
            raise StonesRefused('invalid_stones_kind', f'السطر {n}: نوع الأحجار محسوبة ذهبًا أو مسعَّرة بالقيراط')
        item['stones_kind'] = kind
        if kind == 'as_gold':
            item['stones_value'] = 0.0
            continue
        if invoice_type == SUPPLIER_RETURN:
            raise StonesRefused('priced_stones_return_not_built',
                                f'السطر {n}: مرتجع الأحجار المسعَّرة لم يُبنَ بعد — يُرتجع بفاتورة شراء معكوسة يدويًّا')
        value = _f(item.get('stones_value'))
        if value <= CENT:
            raise StonesRefused('priced_stones_need_value', f'السطر {n}: الأحجار المسعَّرة تحتاج قيمتها بالريال')
        standing = _f(item.get('weight') if item.get('weight') is not None else item.get('total_weight'))
        gold = round(standing - stones, 3)
        if gold <= TOLERANCE:
            raise StonesRefused('stones_heavier_than_line',
                                f'السطر {n}: وزن الأحجار ({stones:.3f}) لا يترك ذهبًا من الوزن ({standing:.3f})')
        item['standing_weight'] = standing
        item['weight'] = gold
        item['stones_value'] = round(value, 2)
        priced_value += value
        any_priced = True
    if any_priced:
        by_karat = {}
        for item in items:
            if isinstance(item, dict) and _f(item.get('weight')) > 0 and item.get('karat') not in (None, ''):
                karat = int(round(_f(item.get('karat'))))
                by_karat[karat] = by_karat.get(karat, 0.0) + _f(item.get('weight'))
        data['supplier_gold_lines'] = [{'karat': k, 'weight': round(w, 3)} for k, w in sorted(by_karat.items())]
    return round(priced_value, 2)


def tax_of(value: float, *, vat_applied, settings) -> float:
    """The priced stones' VAT, as the wages take it: under the invoice's VAT
    decision, at the company's rate."""
    if value <= 0 or vat_applied is not True or settings is None or not getattr(settings, 'tax_enabled', True):
        return 0.0
    return round(value * _f(getattr(settings, 'tax_rate', 0.0)), 2)
