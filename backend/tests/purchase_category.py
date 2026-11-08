"""A supplier purchase line says its category of its karat (services/purchase_lines,
the owner, 8 Nov 2026): the tests' purchase lines take one -- an active, not
scrap category of the line's karat, made once if the test database has none."""
import uuid


def category_of(karat) -> int:
    from models import Category, db
    k = f'{float(karat):g}'
    found = (Category.query.filter_by(karat=k, is_active=True, is_scrap=False).order_by(Category.id).first())
    if found is None:
        found = Category(name=f'تصنيف {k} {uuid.uuid4().hex[:4]}', karat=k, is_active=True, is_scrap=False)
        db.session.add(found)
        db.session.flush()
    return found.id


def categorized(items):
    """The lines, each with its karat's category -- a return's line keeps its own."""
    for item in items:
        if isinstance(item, dict) and not item.get('category_id') and not item.get('original_invoice_item_id') \
                and item.get('karat') not in (None, '', 0):
            item['category_id'] = category_of(item['karat'])
    return items
