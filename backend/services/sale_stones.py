"""A sale line's stones sold by their value (ADR-050 ت6ج).

The owner (23 Oct 2026): a piece renewed with its stones as stones -- on the
showroom's counter, not in its gold -- «تُباع ذهبًا + قيمة أحجار». The line
says them `priced` (ADR-055's word), with their weight and value: its weight
is its gold, and the value is part of its price. A line without a kind, or
`as_gold`, sells as the shop always has -- its stones in its gold.

normalize() is the one rule, applied to the request before it is posted: the
priced lines by karat, or StonesRefused. The value goes to the role
«مبيعات الأحجار», at no cost; the stones leave the sale's gold safe's
counter, within it. A return of such a line is refused until it is built.
"""
from __future__ import annotations

from services.purchase_stones import CENT, KINDS, TOLERANCE, StonesRefused, _f

SALE, SALE_RETURN = 'بيع', 'مرتجع بيع'
ROLE = 'stones_sales'


def _line_net(item: dict) -> float:
    """The line's price before tax, as posting reads it."""
    price = _f(item.get('selling_price') or item.get('price') or item.get('subtotal'))
    return price - abs(_f(item.get('tax_amount', item.get('tax')))) - _f(item.get('discount_amount'))


def normalize(invoice_type: str, data: dict) -> dict:
    """{karat: {'stones': g, 'value': riyals}} of the priced lines -- empty when
    none -- or StonesRefused."""
    if invoice_type == SALE_RETURN:
        _refuse_return_of_priced(data)
        return {}
    if invoice_type != SALE:
        return {}
    priced = {}
    for n, item in enumerate(data.get('items') or [], start=1):
        if not isinstance(item, dict):
            continue
        kind = item.get('stones_kind')
        if not kind:
            continue
        if kind not in KINDS:
            raise StonesRefused('invalid_stones_kind', f'السطر {n}: الأحجار تُحسب ذهبًا أو تُباع بقيمتها')
        if kind == 'as_gold':
            item['stones_value'] = 0.0
            continue
        stones, value = _f(item.get('stones_weight')), _f(item.get('stones_value'))
        if stones <= TOLERANCE:
            raise StonesRefused('priced_stones_need_weight', f'السطر {n}: الأحجار المبيعة بقيمتها تحتاج وزنها')
        if value <= CENT:
            raise StonesRefused('priced_stones_need_value', f'السطر {n}: الأحجار المبيعة بقيمتها تحتاج قيمتها بالريال')
        net = _line_net(item)
        if value >= net - CENT:
            raise StonesRefused('stones_value_above_line',
                                f'السطر {n}: قيمة الأحجار ({value:.2f}) لا تترك للذهب شيئًا من سعر السطر ({net:.2f})')
        try:
            karat = int(round(_f(item.get('karat'))))
        except (TypeError, ValueError):
            karat = 0
        if karat not in (18, 21, 22, 24):
            raise StonesRefused('invalid_karat', f'السطر {n}: عيار السطر مطلوب')
        item['stones_value'] = round(value, 2)
        sums = priced.setdefault(karat, {'stones': 0.0, 'value': 0.0})
        sums['stones'] += stones
        sums['value'] += value
    return priced


def _refuse_return_of_priced(data: dict) -> None:
    """A sale line that sold stones by their value is not returned until its
    return is built: the gold would come back and the stones' value stay sold.
    Its lines are named by the return's own (a whole return, RETURN-FULL-1,
    names every one) or by the original invoice."""
    from models import Invoice, InvoiceItem, db
    originals = []
    for item in data.get('items') or []:
        if isinstance(item, dict) and item.get('original_invoice_item_id'):
            try:
                originals.append(db.session.get(InvoiceItem, int(item['original_invoice_item_id'])))
            except (TypeError, ValueError):
                pass
    if not originals and data.get('original_invoice_id'):
        try:
            invoice = db.session.get(Invoice, int(data['original_invoice_id']))
        except (TypeError, ValueError):
            invoice = None
        originals = list(getattr(invoice, 'items', None) or [])
    if any(getattr(o, 'stones_kind', None) == 'priced' for o in originals if o is not None):
        raise StonesRefused('priced_stones_return_not_built',
                            'مرتجع بيع بأحجار مبيعة بقيمتها لم يُبنَ بعد — يُصحَّح بقيد يدوي')
