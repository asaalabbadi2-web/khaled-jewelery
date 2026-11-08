"""A supplier's purchase line is a category, never an item (the owner, 8 Nov 2026).

A purchase of new gold from a supplier is lots: each line a category, its
karat, weight and wage. The line said a free name and made an item in the
catalogue (create_inline) -- the table that holds the piece (ADR-085), whose
one writer is receiving. Now each line says its category, chosen from the
list: active, not scrap, of the line's karat (ADR-045: a category's karat is
fixed). The name stays as the line's description. Refused before anything is
written, saying the line.

Returns, customers' scrap and the offices' settlements are not supplier lots:
not this law's.
"""
from __future__ import annotations

SUPPLIER_PURCHASE = 'شراء'


class PurchaseLineRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _karat_of(value):
    try:
        return round(float(str(value).strip()), 3)
    except (TypeError, ValueError):
        return None


def refuse_purchase_lines(invoice_type, gold_type, items) -> None:
    """Raise PurchaseLineRefused for the first line that is not a category of its karat."""
    from models import Category, db

    if (invoice_type or '').strip() != SUPPLIER_PURCHASE or (gold_type or 'new').strip().lower() != 'new':
        return
    for n, item in enumerate(items or [], start=1):
        if not isinstance(item, dict):
            continue
        if item.get('create_inline') or item.get('item_id'):
            raise PurchaseLineRefused('purchase_line_is_a_category',
                                      f'السطر {n}: سطر الشراء تصنيف لا صنف؛ القطعة تُسجَّل في الاستلام')
        raw = item.get('category_id')
        if raw in (None, '', 0, '0'):
            raise PurchaseLineRefused('purchase_line_category_required', f'السطر {n}: اختر تصنيف السطر')
        try:
            category = db.session.get(Category, int(raw))
        except (TypeError, ValueError):
            category = None
        if category is None or category.is_active is False or category.is_scrap:
            raise PurchaseLineRefused('purchase_line_category_invalid',
                                      f'السطر {n}: التصنيف غير موجود أو موقوف أو تصنيف كسر')
        category_karat, line_karat = _karat_of(category.karat), _karat_of(item.get('karat'))
        if category_karat is not None and line_karat is not None and category_karat != line_karat:
            raise PurchaseLineRefused('purchase_line_karat_mismatch',
                                      f'السطر {n}: عيار التصنيف «{category.name}» {category_karat:g} '
                                      f'لا يوافق عيار السطر {line_karat:g}')


def supplier_invoice_number(invoice_type, supplier_id, raw, *, exclude_invoice_id=None) -> str | None:
    """The supplier's own invoice number, as saved -- or PurchaseLineRefused.

    Optional (the owner, 8 Nov 2026): empty is None. Written, it is trimmed and
    its Arabic digits read as Latin, and one per supplier among the invoices
    not retracted: a rejected invoice entered again keeps its number. The
    database's partial unique index is the backstop.
    """
    from sqlalchemy import func
    from models import Invoice
    from services.books_invariants import RETRACTED_INVOICE_STATUSES
    from services.categories import latin

    number = latin(raw).strip() if raw is not None else ''
    if not number:
        return None
    if (invoice_type or '').strip() != SUPPLIER_PURCHASE:
        raise PurchaseLineRefused('supplier_invoice_number_not_a_purchase',
                                  'رقم فاتورة المورد لفاتورة شراء من مورد فقط')
    if len(number) > 50:
        raise PurchaseLineRefused('supplier_invoice_number_too_long', 'رقم فاتورة المورد أطول من 50 حرفًا')
    if supplier_id:
        taken = (Invoice.query.filter(Invoice.supplier_id == int(supplier_id),
                                      Invoice.supplier_invoice_number == number,
                                      func.coalesce(Invoice.status, '').notin_(list(RETRACTED_INVOICE_STATUSES)),
                                      Invoice.id != (exclude_invoice_id or -1))
                 .first())
        if taken is not None:
            raise PurchaseLineRefused('supplier_invoice_number_taken',
                                      f'رقم فاتورة المورد {number} مسجَّل لهذا المورد في الفاتورة '
                                      f'{taken.invoice_number}')
    return number
