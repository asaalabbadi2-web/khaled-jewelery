"""Size systems: the sizes the categories share (ADR-093 §2, M0).

The owner (17 Nov 2026): «مقاسات البناجر عندنا تكون 17، 18، 19 وهكذا ...
هناك عدة أنظمة للمقاسات» -- and a supplier's other system «تحول إلى نظامنا
المعتمد». So:
  - a system is shared: the bangles of every karat follow one; a category
    follows one system or none;
  - a size is text, never a number («2.10» is not «2.1»), in one spelling:
    Arabic digits written Latin, a comma a point, spaces gone; unique in its
    system, in its order, with an optional measurement;
  - a size a piece holds or a model comes in is never taken out, and a
    category whose pieces or models hold sizes keeps its system; a system a
    category follows stays;
  - none is written in the code: the owner enters the shop's own.
"""
from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation

from models import Category, Item, SizeSystem, SizeSystemSize, db
from services.categories import latin

LABEL_MAX = 20
NAME_MAX = 60


class SizeRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def normalize_label(text) -> str:
    """A size in its one spelling: «١٨» -> «18», «2,6» / «2٫6» -> «2.6»; text kept («2.10»)."""
    label = latin(text).replace('٫', '.').replace(',', '.').replace('،', '.')
    label = re.sub(r'\s+', '', label)
    if not label:
        raise SizeRefused('size_label_empty', 'اكتب المقاس')
    if len(label) > LABEL_MAX:
        raise SizeRefused('size_label_too_long', f'المقاس {LABEL_MAX} حرفًا على الأكثر')
    return label


def _measurement(raw):
    if raw in (None, ''):
        return None
    try:
        value = Decimal(latin(raw).replace('٫', '.').replace(',', '.').strip())
    except InvalidOperation:
        raise SizeRefused('size_measurement_invalid', 'القياس رقم، أو اتركه فارغًا')
    if value <= 0:
        raise SizeRefused('size_measurement_invalid', 'القياس رقم أكبر من الصفر، أو اتركه فارغًا')
    return value.quantize(Decimal('0.01'))


def _name(raw) -> str:
    name = re.sub(r'\s+', ' ', str(raw or '')).strip()
    if not name:
        raise SizeRefused('size_system_name_empty', 'اكتب اسم النظام')
    if len(name) > NAME_MAX:
        raise SizeRefused('size_system_name_too_long', f'الاسم {NAME_MAX} حرفًا على الأكثر')
    return name


def sizes_of(system: SizeSystem) -> list:
    return SizeSystemSize.query.filter_by(system_id=system.id).order_by(SizeSystemSize.position,
                                                                        SizeSystemSize.id).all()


def pieces_holding(size_ids) -> dict:
    """{size id: how many pieces point at it} -- any piece, in stock or not."""
    if not size_ids:
        return {}
    rows = (db.session.query(Item.size_id, db.func.count(Item.id))
            .filter(Item.size_id.in_(list(size_ids))).group_by(Item.size_id).all())
    return {int(s): int(n) for s, n in rows}


def _renumber(sizes) -> None:
    for i, size in enumerate(sizes, start=1):
        size.position = i


def system_view(system: SizeSystem) -> dict:
    sizes = sizes_of(system)
    held = pieces_holding([s.id for s in sizes])
    categories = Category.query.filter_by(size_system_id=system.id).order_by(Category.name).all()
    return {
        'id': system.id, 'name': system.name, 'measurement_label': system.measurement_label,
        'sizes': [{'id': s.id, 'label': s.label, 'position': s.position,
                   'measurement': float(s.measurement) if s.measurement is not None else None,
                   'pieces': held.get(s.id, 0)} for s in sizes],
        'categories': [{'id': c.id, 'name': c.name} for c in categories],
    }


def list_systems() -> list:
    return [system_view(s) for s in SizeSystem.query.order_by(SizeSystem.name).all()]


def _name_free(name: str, but=None) -> None:
    q = SizeSystem.query.filter(db.func.lower(SizeSystem.name) == name.lower())
    if but is not None:
        q = q.filter(SizeSystem.id != but.id)
    if q.first():
        raise SizeRefused('size_system_name_taken', f'يوجد نظام باسم «{name}»')


def create_system(*, name, measurement_label=None, sizes=(), by: str, now) -> SizeSystem:
    """A system with its sizes in their order; the caller commits."""
    name = _name(name)
    _name_free(name)
    system = SizeSystem(name=name, measurement_label=(str(measurement_label).strip()[:NAME_MAX] or None)
                        if measurement_label else None, created_by=by, created_at=now)
    db.session.add(system)
    db.session.flush()
    for raw in sizes or ():
        add_size(system, label=raw, by=by, now=now)
    return system


def update_system(system: SizeSystem, *, name=None, measurement_label=...) -> SizeSystem:
    if name is not None:
        name = _name(name)
        _name_free(name, but=system)
        system.name = name
    if measurement_label is not ...:
        system.measurement_label = (str(measurement_label).strip()[:NAME_MAX] or None) if measurement_label else None
    db.session.flush()
    return system


def delete_system(system: SizeSystem) -> None:
    followed = Category.query.filter_by(size_system_id=system.id).count()
    if followed:
        raise SizeRefused('size_system_followed', f'«{system.name}» يتبعه {followed} تصنيف: غيّر نظامها أولًا')
    sizes = sizes_of(system)
    if any(pieces_holding([s.id for s in sizes]).values()):
        raise SizeRefused('size_in_use', f'قطع تحمل مقاسات «{system.name}»')
    for size in sizes:
        db.session.delete(size)
    db.session.delete(system)
    db.session.flush()


def _label_free(system: SizeSystem, label: str, but=None) -> None:
    q = SizeSystemSize.query.filter_by(system_id=system.id, label=label)
    if but is not None:
        q = q.filter(SizeSystemSize.id != but.id)
    if q.first():
        raise SizeRefused('size_label_taken', f'المقاس {label} موجود في «{system.name}»')


def add_size(system: SizeSystem, *, label, measurement=None, before_id=None, by: str, now) -> SizeSystemSize:
    """A size at the end, or before *before_id*; the order renumbered."""
    label = normalize_label(label)
    _label_free(system, label)
    sizes = sizes_of(system)
    size = SizeSystemSize(system_id=system.id, label=label, position=0, measurement=_measurement(measurement),
                          created_by=by, created_at=now)
    db.session.add(size)
    at = next((i for i, s in enumerate(sizes) if s.id == before_id), None) if before_id is not None else None
    if before_id is not None and at is None:
        raise SizeRefused('size_not_in_system', 'المقاس الذي يُضاف قبله ليس في هذا النظام')
    sizes.insert(len(sizes) if at is None else at, size)
    _renumber(sizes)
    db.session.flush()
    return size


def update_size(size: SizeSystemSize, *, label=None, measurement=...) -> SizeSystemSize:
    """A spelling corrected reaches every piece: they point at the size, not its text."""
    system = db.session.get(SizeSystem, size.system_id)
    if label is not None:
        label = normalize_label(label)
        _label_free(system, label, but=size)
        size.label = label
    if measurement is not ...:
        size.measurement = _measurement(measurement)
    db.session.flush()
    return size


def reorder(system: SizeSystem, ordered_ids) -> None:
    """The sizes in *ordered_ids*' order -- every size of the system, once."""
    sizes = {s.id: s for s in sizes_of(system)}
    ids = [int(i) for i in ordered_ids or ()]
    if sorted(ids) != sorted(sizes):
        raise SizeRefused('size_order_invalid', 'الترتيب يذكر كل مقاسات النظام مرة واحدة')
    _renumber([sizes[i] for i in ids])
    db.session.flush()


def delete_size(size: SizeSystemSize) -> None:
    held = pieces_holding([size.id]).get(size.id, 0)
    if held:
        raise SizeRefused('size_in_use', f'المقاس {size.label} تحمله {held} قطعة')
    from models import PieceModel, PieceModelSize
    model = (PieceModel.query.join(PieceModelSize, PieceModelSize.model_id == PieceModel.id)
             .filter(PieceModelSize.size_id == size.id).first())
    if model is not None:
        raise SizeRefused('size_in_model', f'المقاس {size.label} من مقاسات الموديل «{model.name}»: أخرجه منه أولًا')
    system = db.session.get(SizeSystem, size.system_id)
    db.session.delete(size)
    db.session.flush()
    _renumber(sizes_of(system))
    db.session.flush()


def set_category_system(category: Category, system_id) -> None:
    """The system a category follows, or none; kept while its pieces hold sizes."""
    new = int(system_id) if system_id not in (None, '', 0, '0') else None
    if new == category.size_system_id:
        return
    if new is not None and db.session.get(SizeSystem, new) is None:
        raise SizeRefused('size_system_not_found', 'نظام المقاسات غير موجود')
    sized = Item.query.filter(Item.category_id == category.id, Item.size_id.isnot(None)).count()
    if sized:
        raise SizeRefused('size_system_in_use',
                          f'«{category.name}» فيه {sized} قطعة لها مقاس: يبقى نظامه حتى تُغيَّر مقاساتها')
    from models import PieceModel, PieceModelSize
    model = (PieceModel.query.join(PieceModelSize, PieceModelSize.model_id == PieceModel.id)
             .filter(PieceModel.category_id == category.id).first())
    if model is not None:
        raise SizeRefused('size_system_in_use',
                          f'موديل «{model.name}» في «{category.name}» له مقاسات من نظامه: أخرجها أولًا')
    category.size_system_id = new
