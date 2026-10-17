"""The names an invoice's type is shown by -- not the type it is stored as.

The owner, 17 Oct 2026: «من شراء من عميل الى شراء كسر، ومن شراء من مورد الى شراء
جديد». The stored invoice_type stays (139 places in the code, the accounting
mappings' operation names, the reports read it); only what a person reads
changes. A supplier's purchase and an office's settled reservation share the
stored type «شراء» -- the office's is scrap, so it reads «شراء كسر من مكتب».
"""
from __future__ import annotations

CUSTOMER_BUY, SUPPLIER_BUY = 'شراء من عميل', 'شراء'
CUSTOMER_BUY_RETURN, SUPPLIER_BUY_RETURN = 'مرتجع شراء', 'مرتجع شراء (مورد)'

LABELS = {
    CUSTOMER_BUY: 'شراء كسر',
    'شراء من مورد': 'شراء جديد',          # the type's old spelling, still on old rows
    SUPPLIER_BUY: 'شراء جديد',
    CUSTOMER_BUY_RETURN: 'مرتجع شراء كسر',
    'مرتجع شراء من عميل': 'مرتجع شراء كسر',
    SUPPLIER_BUY_RETURN: 'مرتجع شراء جديد',
    'مرتجع شراء من مورد': 'مرتجع شراء جديد',
}
OFFICE_BUY = 'شراء كسر من مكتب'


def invoice_type_label(invoice_type: str | None, *, office_id=None) -> str:
    """What a person reads for *invoice_type*; other types read as stored."""
    kind = (invoice_type or '').strip()
    if kind == SUPPLIER_BUY and office_id is not None:
        return OFFICE_BUY
    return LABELS.get(kind, kind)


def label_of(invoice) -> str:
    return invoice_type_label(getattr(invoice, 'invoice_type', None), office_id=getattr(invoice, 'office_id', None))
