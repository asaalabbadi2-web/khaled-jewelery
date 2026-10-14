"""Categories: their name, their karat, their group, scrap (ADR-045 B).

The owner, 14 Oct 2026: Latin digits; every category names its karat and its
karat is fixed once used -- manual entry must not mistake one karat for
another; a group derived from the name, never typed; a «كسر» category per
karat for customer scrap purchases; what is used is stopped, never deleted.

- canonical(name, karat): the name and karat a category is saved with, or
  ValueError -- Latin digits, a known karat, the name ending in it.
- group_name(name, karat): the name without its karat (and «عيار»).
- is_used(category): invoice lines, items or stock allocations point at it.
- assign_scrap_categories(invoice): a customer scrap purchase's lines without
  a category get their karat's scrap category.
"""
from __future__ import annotations

import re

KARATS = ('18', '21', '22', '24')
_ARABIC_DIGITS = str.maketrans('٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789')
CUSTOMER_SCRAP_PURCHASE = 'شراء من عميل'


def latin(text) -> str:
    return str(text or '').translate(_ARABIC_DIGITS)


def canonical(name, karat) -> tuple[str, str]:
    """(name, karat) as a category is saved -- or ValueError."""
    karat = latin(karat).strip()
    if karat.endswith('.0'):
        karat = karat[:-2]
    if karat not in KARATS:
        raise ValueError(f'عيار التصنيف مطلوب، وهو أحد: {"، ".join(KARATS)}')
    name = ' '.join(latin(name).split())
    if not name:
        raise ValueError('اسم التصنيف مطلوب')
    # Only a karat at the end is read as one -- «طقم 3 قطع» names no karat.
    named = re.search(r'(?<!\d)(18|21|22|24)\s*$', name)
    if named is None:
        name = f'{name} {karat}'
    elif named.group(1) != karat:
        raise ValueError(f'الاسم يذكر عيار {named.group(1)} والتصنيف عيار {karat}')
    return name, karat


def group_name(name, karat) -> str:
    """The category's group: its name without its karat and «عيار»."""
    text = ' '.join(latin(name).split())
    k = latin(karat).strip()
    if k:
        text = re.sub(rf'\s*{re.escape(k)}\s*$', '', text)
    text = re.sub(r'\s*عيار\s*$', '', text)
    return text.strip()


def is_used(category) -> bool:
    from models import InvoiceItem, Item, StockLineAllocation, db
    for model, column in ((InvoiceItem, InvoiceItem.category_id), (Item, Item.category_id),
                          (StockLineAllocation, StockLineAllocation.category_id)):
        if db.session.query(model.id).filter(column == category.id).first() is not None:
            return True
    return False


def scrap_category(karat):
    from models import Category
    k = latin(karat).strip()
    if k.endswith('.0'):
        k = k[:-2]
    return Category.query.filter_by(is_scrap=True, karat=k).filter(Category.is_active.isnot(False)).first()


def assign_scrap_categories(invoice) -> int:
    """A customer scrap purchase's lines without a category get their karat's
    scrap category; the number given. Any other invoice is left as it is."""
    from models import InvoiceItem, db
    if (invoice.invoice_type or '').strip() != CUSTOMER_SCRAP_PURCHASE:
        return 0
    given = 0
    for line in InvoiceItem.query.filter_by(invoice_id=invoice.id, category_id=None).all():
        scrap = scrap_category(int(round(float(line.karat or 0))))
        if scrap is not None:
            line.category_id = scrap.id
            given += 1
    if given:
        db.session.flush()
    return given
