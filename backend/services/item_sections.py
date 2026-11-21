"""The shop's sections (ADR-093 amendment; the owner, 21 Nov 2026).

Three layers name a piece: its section -- the kind with no karat («أساور») --
its category -- the section at a karat, the books' unit (its balance, its
wages, tracked by the piece or the weight) -- and its model, a shared design.

A section is a grouping only: no balance, no posting, its figures its
categories'. The owner sets each category's section, once; renaming a
category does not move it. A scrap category takes none: scrap is not shown.

It replaces the group derived from a category's name (services.categories.
group_name), which is now only where the first suggestion comes from: the
name with no karat and nothing in brackets -- «سوار ذهب (دائري) 21» proposed
with «سوار ذهب 18» -- for the owner to change before anything is saved.
"""
from __future__ import annotations

import re

from models import Category, ItemSection, db
from services.categories import group_name


class SectionRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _name(raw) -> str:
    name = ' '.join(str(raw or '').split())
    if not name:
        raise SectionRefused('section_name_required', 'اسم القسم مطلوب')
    if len(name) > 60:
        raise SectionRefused('section_name_long', 'اسم القسم 60 حرفًا على الأكثر')
    return name


def _unique(name: str, *, other_than=None) -> None:
    clash = ItemSection.query.filter(db.func.lower(ItemSection.name) == name.lower())
    if other_than is not None:
        clash = clash.filter(ItemSection.id != other_than)
    if clash.first() is not None:
        raise SectionRefused('section_exists', f'القسم «{name}» موجود')


def sections() -> list:
    """The sections in their order, each with its categories."""
    rows = ItemSection.query.order_by(ItemSection.sort_order, ItemSection.name).all()
    by_section: dict = {}
    for c in Category.query.filter(Category.section_id.isnot(None)).order_by(Category.name):
        by_section.setdefault(c.section_id, []).append({'id': c.id, 'name': c.name, 'karat': c.karat})
    return [{'id': s.id, 'name': s.name, 'sort_order': s.sort_order, 'is_active': s.is_active,
             'categories': by_section.get(s.id, [])} for s in rows]


def create_section(name, *, by: str, now, sort_order=None) -> ItemSection:
    name = _name(name)
    _unique(name)
    section = ItemSection(name=name, sort_order=int(sort_order or 0), is_active=True, created_at=now, created_by=by)
    db.session.add(section)
    db.session.flush()
    return section


def update_section(section: ItemSection, *, name=None, sort_order=None, is_active=None) -> ItemSection:
    if name is not None:
        name = _name(name)
        _unique(name, other_than=section.id)
        section.name = name
    if sort_order is not None:
        section.sort_order = int(sort_order)
    if is_active is not None:
        section.is_active = bool(is_active)
    db.session.flush()
    return section


def delete_section(section: ItemSection) -> None:
    """A section no category is in; one in use is stopped instead."""
    used = Category.query.filter_by(section_id=section.id).count()
    if used:
        raise SectionRefused('section_in_use', f'«{section.name}» فيه {used} تصنيف: انقلها أو أوقفه بدل حذفه')
    db.session.delete(section)
    db.session.flush()


def set_category_section(category: Category, section_id) -> None:
    """A category's section, or none; a scrap category none."""
    new = int(section_id) if section_id not in (None, '', 0, '0') else None
    if new == category.section_id:
        return
    if new is not None:
        if category.is_scrap:
            raise SectionRefused('section_scrap', f'«{category.name}» تصنيف كسر: الكسر لا يُعرض فلا قسم له')
        if db.session.get(ItemSection, new) is None:
            raise SectionRefused('section_not_found', 'القسم غير موجود')
    category.section_id = new
    db.session.flush()


def suggested_name(category: Category) -> str | None:
    """The first suggestion for a category's section: its name with no karat
    and nothing in brackets -- none for scrap."""
    if category.is_scrap:
        return None
    base = re.sub(r'\s*\([^)]*\)\s*', ' ', group_name(category.name, category.karat))
    return ' '.join(base.split()) or None


def suggestions() -> list:
    """Each category that may have a section: its section now, and the name
    suggested -- the owner's to change before anything is saved."""
    return [{'category_id': c.id, 'category_name': c.name, 'karat': c.karat, 'is_active': c.is_active is not False,
             'section_id': c.section_id, 'suggested': suggested_name(c)}
            for c in Category.query.filter(Category.is_scrap.isnot(True)).order_by(Category.name)]


def assign(assignments, *, by: str, now) -> list:
    """[{category_id, section_name}] saved at once: each named section found or
    made once, each category set to it; an empty name takes its section away."""
    if not isinstance(assignments, list) or not assignments:
        raise SectionRefused('section_assignments', 'لا تصنيف ليُحفظ قسمه')
    made = {}
    for row in assignments:
        try:
            category = db.session.get(Category, int(row['category_id']))
        except (KeyError, TypeError, ValueError):
            category = None
        if category is None:
            raise SectionRefused('section_category_not_found', 'تصنيف غير موجود')
        raw = ' '.join(str(row.get('section_name') or '').split())
        if not raw:
            set_category_section(category, None)
            continue
        name = _name(raw)
        section = made.get(name.lower()) or ItemSection.query.filter(
            db.func.lower(ItemSection.name) == name.lower()).first()
        if section is None:
            section = create_section(name, by=by, now=now)
        made[name.lower()] = section
        set_category_section(category, section.id)
    return sections()
