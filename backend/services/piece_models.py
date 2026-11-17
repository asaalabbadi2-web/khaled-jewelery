"""Piece models: what a model's pieces share (ADR-093 §1, M1).

The owner (17 Nov 2026): bangles of one model share their shape, their wage
and the rest, and differ in weight and size; a photo is required on the
screens. A model is:
  - a description: no balance (its stock is counted from its pieces), never
    the source of a piece's wage (that is its receipt line's, ADR-087 §6) --
    its expected wage is compared with the invoice's at receiving (M2);
  - of one category, never a scrap one; its name unique in it;
  - in sizes of its category's size system only; a size a piece of it holds
    stays; its category fixed once a piece is of it;
  - stopped, never deleted, once a piece is of it;
  - its photo sized down on the device: here a JPEG, PNG or WebP by its own
    first bytes, within its size, and a thumbnail with it for the lists.
"""
from __future__ import annotations

import base64
import binascii
import re
from decimal import Decimal, InvalidOperation

from models import Category, Item, PieceModel, PieceModelSize, SizeSystemSize, db
from services.categories import latin

NAME_MAX = 100
CODE_MAX = 60
PHOTO_MAX_BYTES = 600_000          # a photo sized down to 1200 px on the device, with room
THUMBNAIL_MAX_BYTES = 60_000       # 240 px
_DATA_URI = re.compile(r'^data:image/(jpeg|png|webp);base64,([A-Za-z0-9+/=\s]+)$')
_MAGIC = {
    'jpeg': lambda b: b[:3] == b'\xff\xd8\xff',
    'png': lambda b: b[:8] == b'\x89PNG\r\n\x1a\n',
    'webp': lambda b: b[:4] == b'RIFF' and b[8:12] == b'WEBP',
}


class ModelRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _image(uri, *, max_bytes: int, what: str) -> str:
    """*uri* if it is an image of its type within *max_bytes* -- or ModelRefused."""
    found = _DATA_URI.match(str(uri or '').strip())
    if not found:
        raise ModelRefused('photo_invalid', f'{what}: صورة JPEG أو PNG أو WebP')
    kind, payload = found.groups()
    try:
        raw = base64.b64decode(re.sub(r'\s+', '', payload), validate=True)
    except (binascii.Error, ValueError):
        raise ModelRefused('photo_invalid', f'{what}: الملف لا يُقرأ')
    if not _MAGIC[kind](raw):
        raise ModelRefused('photo_invalid', f'{what}: الملف ليس صورة {kind.upper()}')
    if len(raw) > max_bytes:
        raise ModelRefused('photo_too_large', f'{what}: {len(raw) // 1000} ك.ب، والحد {max_bytes // 1000} ك.ب')
    return f'data:image/{kind};base64,' + base64.b64encode(raw).decode()


def _name(raw) -> str:
    name = re.sub(r'\s+', ' ', str(raw or '')).strip()
    if not name:
        raise ModelRefused('model_name_empty', 'اكتب اسم الموديل')
    if len(name) > NAME_MAX:
        raise ModelRefused('model_name_too_long', f'الاسم {NAME_MAX} حرفًا على الأكثر')
    return name


def _wage(raw):
    if raw in (None, ''):
        return None
    try:
        value = Decimal(latin(raw).replace('٫', '.').replace(',', '.').strip())
    except InvalidOperation:
        raise ModelRefused('model_wage_invalid', 'الأجرة المتوقعة رقم، أو اتركها فارغة')
    if value < 0:
        raise ModelRefused('model_wage_invalid', 'الأجرة المتوقعة لا تكون سالبة')
    return value.quantize(Decimal('0.01'))


def _category(category_id) -> Category:
    category = db.session.get(Category, int(category_id)) if category_id not in (None, '') else None
    if category is None:
        raise ModelRefused('model_category_required', 'اختر تصنيف الموديل')
    if category.is_scrap:
        raise ModelRefused('model_category_scrap', 'تصنيف الكسر لا موديلات له')
    return category


def _name_free(category_id: int, name: str, but=None) -> None:
    q = PieceModel.query.filter(PieceModel.category_id == category_id,
                                db.func.lower(PieceModel.name) == name.lower())
    if but is not None:
        q = q.filter(PieceModel.id != but.id)
    if q.first():
        raise ModelRefused('model_name_taken', f'يوجد موديل باسم «{name}» في هذا التصنيف')


def pieces_of(model_ids) -> dict:
    """{model id: how many pieces are of it} -- any piece, in stock or not."""
    if not model_ids:
        return {}
    rows = (db.session.query(Item.model_id, db.func.count(Item.id))
            .filter(Item.model_id.in_(list(model_ids))).group_by(Item.model_id).all())
    return {int(m): int(n) for m, n in rows}


def model_sizes(model: PieceModel) -> list:
    return (SizeSystemSize.query.join(PieceModelSize, PieceModelSize.size_id == SizeSystemSize.id)
            .filter(PieceModelSize.model_id == model.id)
            .order_by(SizeSystemSize.position, SizeSystemSize.id).all())


def _check_sizes(category: Category, size_ids) -> set:
    """*size_ids* if every one is of *category*'s size system -- or ModelRefused, nothing written."""
    wanted = {int(i) for i in size_ids or ()}
    if wanted:
        found = SizeSystemSize.query.filter(SizeSystemSize.id.in_(wanted)).all()
        if len(found) != len(wanted) or category.size_system_id is None or \
                any(s.system_id != category.size_system_id for s in found):
            raise ModelRefused('size_not_in_category', f'المقاس ليس من نظام مقاسات «{category.name}»')
    return wanted


def _set_sizes(model: PieceModel, size_ids) -> None:
    """The sizes it comes in: its category's system's; one a piece of it holds stays."""
    wanted = _check_sizes(db.session.get(Category, model.category_id), size_ids)
    current = {r.size_id: r for r in PieceModelSize.query.filter_by(model_id=model.id)}
    dropped = set(current) - wanted
    if dropped:
        held = (db.session.query(SizeSystemSize.label)
                .join(Item, Item.size_id == SizeSystemSize.id)
                .filter(Item.model_id == model.id, SizeSystemSize.id.in_(dropped)).distinct().all())
        if held:
            raise ModelRefused('size_in_use', f'قطع من «{model.name}» تحمل المقاس {held[0][0]}')
        for size_id in dropped:
            db.session.delete(current[size_id])
    for size_id in wanted - set(current):
        db.session.add(PieceModelSize(model_id=model.id, size_id=size_id))
    db.session.flush()


def _photo_pair(photo, thumbnail):
    if photo in (None, '') and thumbnail in (None, ''):
        return None, None
    if photo in (None, '') or thumbnail in (None, ''):
        raise ModelRefused('photo_invalid', 'الصورة ومصغّرتها معًا')
    return (_image(photo, max_bytes=PHOTO_MAX_BYTES, what='الصورة'),
            _image(thumbnail, max_bytes=THUMBNAIL_MAX_BYTES, what='المصغّرة'))


def model_view(model: PieceModel, *, photo: bool = False, pieces: int | None = None) -> dict:
    category = db.session.get(Category, model.category_id)
    view = {
        'id': model.id, 'name': model.name,
        'category': {'id': category.id, 'name': category.name, 'size_system_id': category.size_system_id},
        'supplier_code': model.supplier_code,
        'expected_wage_per_gram': float(model.expected_wage_per_gram)
        if model.expected_wage_per_gram is not None else None,
        'has_stones': bool(model.has_stones), 'is_active': model.is_active is not False,
        'sizes': [{'id': s.id, 'label': s.label, 'position': s.position} for s in model_sizes(model)],
        'thumbnail': model.thumbnail, 'has_photo': model.photo is not None,
        'pieces': pieces if pieces is not None else pieces_of([model.id]).get(model.id, 0),
    }
    if photo:
        view['photo'] = model.photo
    return view


def list_models(*, category_id=None, q=None, include_inactive=False) -> list:
    query = PieceModel.query
    if category_id not in (None, ''):
        query = query.filter(PieceModel.category_id == int(category_id))
    if not include_inactive:
        query = query.filter(PieceModel.is_active.is_(True))
    text = re.sub(r'\s+', ' ', str(q or '')).strip()
    if text:
        like = f'%{text}%'
        query = query.filter(db.or_(PieceModel.name.ilike(like), PieceModel.supplier_code.ilike(like)))
    models = query.order_by(PieceModel.name).all()
    counted = pieces_of([m.id for m in models])
    return [model_view(m, pieces=counted.get(m.id, 0)) for m in models]


def create_model(*, category_id, name, supplier_code=None, expected_wage_per_gram=None, has_stones=False,
                 size_ids=(), photo=None, thumbnail=None, by: str, now) -> PieceModel:
    """A model; the caller commits."""
    category = _category(category_id)
    name = _name(name)
    _name_free(category.id, name)
    photo, thumbnail = _photo_pair(photo, thumbnail)
    _check_sizes(category, size_ids)                      # refused before anything is written
    model = PieceModel(category_id=category.id, name=name,
                       supplier_code=(str(supplier_code).strip()[:CODE_MAX] or None) if supplier_code else None,
                       expected_wage_per_gram=_wage(expected_wage_per_gram), has_stones=bool(has_stones),
                       photo=photo, thumbnail=thumbnail, is_active=True, created_by=by, created_at=now)
    db.session.add(model)
    db.session.flush()
    _set_sizes(model, size_ids)
    return model


_UNSET = object()


def update_model(model: PieceModel, *, now, name=None, category_id=_UNSET, supplier_code=_UNSET,
                 expected_wage_per_gram=_UNSET, has_stones=None, size_ids=None, photo=_UNSET,
                 thumbnail=_UNSET, is_active=None) -> PieceModel:
    """What is given changes; its category fixed once a piece is of it."""
    if category_id is not _UNSET and category_id not in (None, '') and int(category_id) != model.category_id:
        if pieces_of([model.id]).get(model.id):
            raise ModelRefused('model_in_use', f'قطع من «{model.name}» مسجّلة: تصنيفه ثابت')
        model.category_id = _category(category_id).id
        if size_ids is None:
            size_ids = ()                      # its sizes were the old category's
    if name is not None:
        model.name = _name(name)
    _name_free(model.category_id, model.name, but=model)
    if supplier_code is not _UNSET:
        model.supplier_code = (str(supplier_code).strip()[:CODE_MAX] or None) if supplier_code else None
    if expected_wage_per_gram is not _UNSET:
        model.expected_wage_per_gram = _wage(expected_wage_per_gram)
    if has_stones is not None:
        model.has_stones = bool(has_stones)
    if photo is not _UNSET or thumbnail is not _UNSET:
        model.photo, model.thumbnail = _photo_pair(None if photo is _UNSET else photo,
                                                   None if thumbnail is _UNSET else thumbnail)
    if is_active is not None:
        model.is_active = bool(is_active)
    if size_ids is not None:
        _set_sizes(model, size_ids)
    model.updated_at = now
    db.session.flush()
    return model


def delete_model(model: PieceModel) -> None:
    held = pieces_of([model.id]).get(model.id, 0)
    if held:
        raise ModelRefused('model_in_use', f'{held} قطعة من «{model.name}»: أوقفه بدل حذفه')
    PieceModelSize.query.filter_by(model_id=model.id).delete()
    db.session.delete(model)
    db.session.flush()
