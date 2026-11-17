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
  - its photo and thumbnail are files in the attachments' store (ADR-094),
    sized down on the device and checked there, linked in its own
    transaction -- never text in the books; a photo replaced stays stored.
"""
from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation

from models import Category, Item, PieceModel, PieceModelSize, SizeSystemSize, db
from services.categories import latin

NAME_MAX = 100
CODE_MAX = 60


class ModelRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


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


def _photo_ids(photo_id, thumbnail_id, *, by: str):
    """(photo id, thumbnail id) sent to the attachments' store, both or
    neither -- each its sender's, pending, of its role (ADR-094); or none."""
    from services.attachments import MODEL_PHOTO, MODEL_THUMBNAIL, AttachmentRefused, check_linkable
    if photo_id in (None, '') and thumbnail_id in (None, ''):
        return None, None
    if photo_id in (None, '') or thumbnail_id in (None, ''):
        raise ModelRefused('photo_invalid', 'الصورة ومصغّرتها معًا')
    try:
        check_linkable([photo_id], role=MODEL_PHOTO, by=by)
        check_linkable([thumbnail_id], role=MODEL_THUMBNAIL, by=by)
    except AttachmentRefused as refused:
        raise ModelRefused(refused.code, refused.message) from None
    return int(photo_id), int(thumbnail_id)


def _link_photo(model: PieceModel, photo_id, thumbnail_id, *, by: str, now) -> None:
    from services.attachments import MODEL_PHOTO, MODEL_THUMBNAIL, PIECE_MODEL, link
    if photo_id is not None:
        link([photo_id], entity_type=PIECE_MODEL, entity_id=model.id, role=MODEL_PHOTO, by=by, now=now)
        link([thumbnail_id], entity_type=PIECE_MODEL, entity_id=model.id, role=MODEL_THUMBNAIL, by=by, now=now)
    model.photo_id, model.thumbnail_id = photo_id, thumbnail_id


def model_view(model: PieceModel, *, pieces: int | None = None) -> dict:
    category = db.session.get(Category, model.category_id)
    view = {
        'id': model.id, 'name': model.name,
        'category': {'id': category.id, 'name': category.name, 'size_system_id': category.size_system_id},
        'supplier_code': model.supplier_code,
        'expected_wage_per_gram': float(model.expected_wage_per_gram)
        if model.expected_wage_per_gram is not None else None,
        'has_stones': bool(model.has_stones), 'is_active': model.is_active is not False,
        'sizes': [{'id': s.id, 'label': s.label, 'position': s.position} for s in model_sizes(model)],
        'photo_id': model.photo_id, 'thumbnail_id': model.thumbnail_id, 'has_photo': model.photo_id is not None,
        'pieces': pieces if pieces is not None else pieces_of([model.id]).get(model.id, 0),
    }
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
                 size_ids=(), photo_id=None, thumbnail_id=None, by: str, now) -> PieceModel:
    """A model; its photo linked from the attachments' store. The caller commits."""
    category = _category(category_id)
    name = _name(name)
    _name_free(category.id, name)
    photo_id, thumbnail_id = _photo_ids(photo_id, thumbnail_id, by=by)
    _check_sizes(category, size_ids)                      # refused before anything is written
    model = PieceModel(category_id=category.id, name=name,
                       supplier_code=(str(supplier_code).strip()[:CODE_MAX] or None) if supplier_code else None,
                       expected_wage_per_gram=_wage(expected_wage_per_gram), has_stones=bool(has_stones),
                       is_active=True, created_by=by, created_at=now)
    db.session.add(model)
    db.session.flush()
    _link_photo(model, photo_id, thumbnail_id, by=by, now=now)
    _set_sizes(model, size_ids)
    return model


_UNSET = object()


def update_model(model: PieceModel, *, now, by: str = 'system', name=None, category_id=_UNSET,
                 supplier_code=_UNSET, expected_wage_per_gram=_UNSET, has_stones=None, size_ids=None,
                 photo_id=_UNSET, thumbnail_id=_UNSET, is_active=None) -> PieceModel:
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
    if photo_id is not _UNSET or thumbnail_id is not _UNSET:
        photo_id = None if photo_id is _UNSET else photo_id
        thumbnail_id = None if thumbnail_id is _UNSET else thumbnail_id
        same = (photo_id in (None, '') and model.photo_id is None) or (
            photo_id not in (None, '') and int(photo_id) == model.photo_id
            and thumbnail_id not in (None, '') and int(thumbnail_id) == model.thumbnail_id)
        if not same:                       # a new photo linked; the old stays in the store, never deleted
            _link_photo(model, *_photo_ids(photo_id, thumbnail_id, by=by), by=by, now=now)
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


# ── what is in stock, by the model and the size (M4) ───────────────────────

def _tally(rows) -> dict:
    weights = [float(p.weight or 0.0) for p, _ in rows]
    return {'count': len(weights), 'weight': round(sum(weights), 3),
            'lightest': round(min(weights), 3) if weights else None,
            'heaviest': round(max(weights), 3) if weights else None}


def _by_size(rows, offered) -> list:
    """One row a size: *offered* in their order (none held: zero -- «نفد»),
    then any other size held, then the pieces with no size."""
    by_size: dict = {}
    for piece, place in rows:
        by_size.setdefault(piece.size_id, []).append((piece, place))
    labels = {s.id: s for s in SizeSystemSize.query.filter(
        SizeSystemSize.id.in_([i for i in by_size if i is not None] or [-1]))}
    order = [s.id for s in offered] + sorted((i for i in by_size if i is not None and i not in
                                              {s.id for s in offered}),
                                             key=lambda i: (labels[i].position, i))
    sized = {s.id: s for s in offered} | labels
    out = [{'size': {'id': i, 'label': sized[i].label}, **_tally(by_size.get(i, []))} for i in order]
    if None in by_size:
        out.append({'size': None, **_tally(by_size[None])})
    return out


def _system_sizes(category: Category) -> list:
    if category.size_system_id is None:
        return []
    return SizeSystemSize.query.filter_by(system_id=category.size_system_id).order_by(
        SizeSystemSize.position, SizeSystemSize.id).all()


def models_board(category_id) -> dict:
    """A category's models and what is in stock of each, size by size; the
    pieces with no model in a row of their own -- so the models and «بلا
    موديل» add up to the category's pieces in stock (ADR-093 §4)."""
    from services.pieces import stock_pieces
    category = db.session.get(Category, int(category_id)) if category_id not in (None, '') else None
    if category is None:
        raise ModelRefused('model_category_required', 'اختر التصنيف')
    rows = stock_pieces(category.id)
    by_model: dict = {}
    for piece, place in rows:
        by_model.setdefault(piece.model_id, []).append((piece, place))
    system = _system_sizes(category)
    models = PieceModel.query.filter_by(category_id=category.id).order_by(PieceModel.name).all()
    board = []
    for model in models:
        held = by_model.get(model.id, [])
        if model.is_active is False and not held:
            continue
        named = model_sizes(model)
        sizes = _by_size(held, named or [])
        board.append({**model_view(model, pieces=len(held)), 'stock': _tally(held), 'by_size': sizes,
                      'missing': [r['size']['label'] for r in sizes if r['size'] and r['count'] == 0]})
    loose = by_model.get(None, [])
    return {
        'category': {'id': category.id, 'name': category.name, 'size_system_id': category.size_system_id},
        'sizes': [{'id': s.id, 'label': s.label} for s in system],
        'in_stock': _tally(rows),
        'in_models': _tally([r for r in rows if r[0].model_id is not None]),
        'models_count': len(board),
        'models': board,
        'no_model': {**_tally(loose), 'by_size': _by_size(loose, [])},
    }


def stock_grid(*, category_id=None, model_id=None) -> dict:
    """The pieces in stock of a model -- or of a category with no model --
    size by size, each size's pieces lightest first with their place: what
    is asked for at the counter («this shape in 18»)."""
    from services.pieces import stock_pieces
    model = None
    if model_id not in (None, '', 'none'):
        model = db.session.get(PieceModel, int(model_id))
        if model is None:
            raise ModelRefused('model_not_found', 'الموديل غير موجود')
        category = db.session.get(Category, model.category_id)
    else:
        category = db.session.get(Category, int(category_id)) if category_id not in (None, '') else None
        if category is None:
            raise ModelRefused('model_category_required', 'اختر التصنيف')
    rows = [(p, place) for p, place in stock_pieces(category.id) if p.model_id == (model.id if model else None)]
    offered = model_sizes(model) if model is not None else []
    grid = _by_size(rows, offered)
    by_size: dict = {}
    for piece, place in rows:
        by_size.setdefault(piece.size_id, []).append((piece, place))
    for row in grid:
        held = by_size.get(row['size']['id'] if row['size'] else None, [])
        row['pieces'] = [{'id': p.id, 'item_code': p.item_code, 'weight': round(float(p.weight or 0.0), 3),
                          'location': {'id': place.id, 'name': place.name} if place else None}
                         for p, place in sorted(held, key=lambda r: (float(r[0].weight or 0.0), r[0].item_code))]
    return {'category': {'id': category.id, 'name': category.name},
            'model': model_view(model, pieces=len(rows)) if model is not None else None,
            'stock': _tally(rows), 'by_size': grid}
