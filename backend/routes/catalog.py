"""Catalog domain routes — catalog_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, date, timedelta

from flask import Blueprint, g, jsonify, request
from sqlalchemy import func, and_, or_

from models import db, Category, InvoiceItem, Item
from utils import normalize_number

from core.dates import _parse_iso_date
from auth_decorators import require_permission

from pricing.karat_service import convert_to_main_karat
from code_generator import generate_item_code, validate_item_code

catalog_bp = Blueprint('catalog', __name__)

@catalog_bp.route('/items/<int:id>', methods=['PUT'])
@require_permission('items.edit')
def update_item(id):
    """
    تحديث صنف موجود
    
    لا يتم تحديث item_code بعد الإنشاء
    إذا تم تحديث barcode إلى فارغ، يُولّد تلقائياً من item_code
    """
    from code_generator import generate_barcode_from_item_code
    
    item = Item.query.get_or_404(id)
    data = request.json
    
    # Update item details (but not item_code)
    item.name = data.get('name', item.name)
    
    # إذا تم حذف barcode، أعد توليده
    new_barcode = data.get('barcode', item.barcode)
    if not new_barcode:
        new_barcode = generate_barcode_from_item_code(item.item_code)
    item.barcode = new_barcode
    
    item.karat = normalize_number(str(data.get('karat', item.karat)))
    item.weight = normalize_number(str(data.get('weight', item.weight)))
    item.count = normalize_number(str(data.get('count', item.count)))
    item.wage = normalize_number(str(data.get('wage', item.wage)))
    item.manufacturing_wage_per_gram = normalize_number(str(data.get('manufacturing_wage_per_gram', item.manufacturing_wage_per_gram)))
    if 'category_id' in data:
        item.category_id = data.get('category_id')
    item.description = data.get('description', item.description)
    item.price = normalize_number(str(data.get('price', item.price)))
    item.stock = normalize_number(str(data.get('stock', item.stock)))
    
    db.session.commit()
    return jsonify({
        'result': 'success',
        'item_code': item.item_code,
        'barcode': item.barcode
    })

@catalog_bp.route('/items/<int:id>', methods=['DELETE'])
@require_permission('items.delete')
def delete_item(id):
    item = Item.query.get_or_404(id)
    db.session.delete(item)
    db.session.commit()
    return jsonify({'result': 'success'})
@catalog_bp.route('/items', methods=['GET'])
@require_permission('items.view')
def get_items():
    query = Item.query

    # Optional filtering by category to support separating purchase vs sale items
    category_id = request.args.get('category_id')
    exclude_category_id = request.args.get('exclude_category_id')

    if category_id not in (None, '', 'null'):
        try:
            query = query.filter(Item.category_id == int(category_id))
        except Exception:
            return jsonify({'error': 'category_id غير صالح'}), 400

    if exclude_category_id not in (None, '', 'null'):
        try:
            query = query.filter(Item.category_id != int(exclude_category_id))
        except Exception:
            return jsonify({'error': 'exclude_category_id غير صالح'}), 400

    items = query.all()
    return jsonify([
        {
            'id': i.id,
            'item_code': i.item_code,
            'name': i.name,
            'barcode': i.barcode,
            'category_id': i.category_id,
            'category_name': i.category.name if i.category else None,
            'karat': i.karat,
            'weight': i.weight,
            'count': i.count,
            'wage': i.wage,
            'manufacturing_wage_per_gram': i.manufacturing_wage_per_gram,
            'description': i.description,
            'price': i.price,
            'stock': i.stock
        } for i in items
    ])

@catalog_bp.route('/items/search/barcode/<barcode>', methods=['GET'])
@require_permission('items.view')
def search_item_by_barcode(barcode):
    """
    البحث عن صنف بالباركود
    يُستخدم عند مسح الباركود لإضافة الصنف تلقائياً للفاتورة
    """
    query = Item.query.filter_by(barcode=barcode)

    # Optional category filtering
    category_id = request.args.get('category_id')
    exclude_category_id = request.args.get('exclude_category_id')
    if category_id not in (None, '', 'null'):
        try:
            query = query.filter(Item.category_id == int(category_id))
        except Exception:
            return jsonify({'error': 'category_id غير صالح'}), 400
    if exclude_category_id not in (None, '', 'null'):
        try:
            query = query.filter(Item.category_id != int(exclude_category_id))
        except Exception:
            return jsonify({'error': 'exclude_category_id غير صالح'}), 400

    item = query.first()
    if not item:
        return jsonify({'error': 'الصنف غير موجود'}), 404
    
    return jsonify({
        'id': item.id,
        'item_code': item.item_code,
        'name': item.name,
        'barcode': item.barcode,
        'category_id': item.category_id,
        'category_name': item.category.name if item.category else None,
        'karat': item.karat,
        'weight': item.weight,
        'count': item.count,
        'wage': item.wage,
        'manufacturing_wage_per_gram': item.manufacturing_wage_per_gram or 0.0,
        'description': item.description,
        'price': item.price,
        'stock': item.stock
    })

# ==================== Purchase Items (Simple List) ====================

@catalog_bp.route('/purchase-items', methods=['GET'])
@require_permission('items.view')
def get_purchase_items():
    """The scrap purchase screen's item names: the items of the scrap
    categories, one per karat (ADR-045 B) -- not a karat-less «أصناف الشراء»."""
    items = (Item.query.join(Category, Category.id == Item.category_id)
             .filter(Category.is_scrap.is_(True)).order_by(Item.name.asc()).all())
    return jsonify([
        {
            'id': i.id,
            'item_code': i.item_code,
            'name': i.name,
            'barcode': i.barcode,
            'karat': i.karat,
            'category_id': i.category_id,
            'category_name': i.category.name if i.category else None,
        }
        for i in items
    ])


@catalog_bp.route('/purchase-items', methods=['POST'])
@require_permission('items.create')
def create_purchase_item():
    """A scrap item name in its karat's scrap category. It failed on every call
    (an unimported barcode generator) after creating «أصناف الشراء»."""
    from services.categories import scrap_category
    data = request.get_json() or {}
    name = (data.get('name') or '').strip()
    if not name:
        return jsonify({'error': 'اسم الصنف مطلوب'}), 400
    karat = str(normalize_number(str(data.get('karat', '')))).strip()
    category = scrap_category(karat)
    if category is None:
        return jsonify({'error': f'لا تصنيف كسر لعيار {karat}'}), 400
    try:
        item = _new_item({'name': name, 'karat': karat, 'category_id': category.id, 'weight': 0, 'count': 0,
                          'price': 0, 'stock': 0, 'description': 'صنف شراء (كسر)'})
        db.session.commit()
    except ValueError as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 400
    return jsonify({'id': item.id, 'item_code': item.item_code, 'name': item.name, 'barcode': item.barcode,
                    'karat': item.karat, 'category_id': item.category_id,
                    'category_name': category.name}), 201


@catalog_bp.route('/purchase-items/<int:item_id>', methods=['DELETE'])
@require_permission('items.delete')
def delete_purchase_item(item_id):
    """A scrap item name, unused, leaves its scrap category's list."""
    item = Item.query.get_or_404(item_id)
    if item.category is None or not item.category.is_scrap:
        return jsonify({'error': 'لا يمكن حذف هذا الصنف من قائمة أصناف الشراء'}), 400
    if InvoiceItem.query.filter_by(item_id=item.id).first() is not None:
        return jsonify({'error': 'الصنف مستعمل في فواتير'}), 409

    db.session.delete(item)
    db.session.commit()
    return jsonify({'result': 'success'})

def _new_item(data: dict) -> Item:
    """The one item creation: its code generated (or validated), its barcode
    from the code when none is given. Flushed, not committed -- the caller
    commits, so several items stay one transaction (quick add)."""
    from code_generator import generate_barcode_from_item_code

    item_code = data.get('item_code')
    if not item_code:
        item_code = generate_item_code()
    else:
        validation = validate_item_code(item_code)
        if not validation['is_valid']:
            raise ValueError(validation['message'])
    barcode = data.get('barcode') or generate_barcode_from_item_code(item_code)

    def number(key, default=None):
        # An empty number is NULL, not '' -- '' reached the float columns and
        # the insert failed (a wage left empty).
        raw = normalize_number(str(data.get(key, '') if data.get(key) is not None else ''))
        return raw if str(raw).strip() != '' else default

    item = Item(
        item_code=item_code,
        name=data['name'],
        barcode=barcode,
        category_id=data.get('category_id'),
        karat=number('karat'),
        weight=number('weight'),
        count=number('count'),
        wage=number('wage'),
        manufacturing_wage_per_gram=number('manufacturing_wage_per_gram', 0),
        description=data.get('description'),
        price=number('price', 0),
        stock=number('stock', 0),
        has_stones=bool(data.get('has_stones', False)),
        stones_weight=float(data.get('stones_weight') or 0.0),
        stones_value=float(data.get('stones_value') or 0.0),
    )
    db.session.add(item)
    db.session.flush()
    return item


@catalog_bp.route('/items', methods=['POST'])
@require_permission('items.create')
def add_item():
    """
    إضافة صنف جديد

    يتم توليد item_code تلقائياً
    إذا لم يُدخل barcode، يتم توليده تلقائياً من item_code
    """
    data = request.json
    try:
        item = _new_item(data)
        db.session.commit()
        return jsonify({
            'id': item.id,
            'item_code': item.item_code,
            'barcode': item.barcode
        }), 201
    except ValueError as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 400
    except Exception as e:
        db.session.rollback()
        # تحقق من خطأ التكرار
        if 'item_code' in str(e):
            return jsonify({'error': f'كود الصنف {data.get("item_code")} مستخدم بالفعل'}), 409
        if 'barcode' in str(e):
            return jsonify({'error': f'الباركود {data.get("barcode")} مستخدم بالفعل'}), 409
        return jsonify({'error': str(e)}), 500


@catalog_bp.route('/items/quick-add', methods=['POST'])
@require_permission('items.create')
def quick_add_items():
    """Several pieces in one go -- «إضافة سريعة» and «استنساخ» (ADR-045 B).

    Body: base_name, category_id, karat, wage_per_gram, has_stones, pieces:
    [{weight, name?, description?, stones_weight?, stones_value?}]. Each piece
    is one item (its own code and barcode), its wage the wage per gram times
    its weight. A piece's karat is its category's -- manual entry must not
    mistake one karat for another (the owner, 14 Oct 2026). All or none.
    """
    data = request.json or {}
    base_name = (data.get('base_name') or '').strip()
    pieces = data.get('pieces') or []
    karat = str(normalize_number(str(data.get('karat', '')))).strip()
    if not base_name or not pieces:
        return jsonify({'error': 'الاسم الأساسي وقطعة واحدة على الأقل مطلوبة'}), 400
    category = db.session.get(Category, int(data['category_id'])) if data.get('category_id') else None
    if category is not None and str(category.karat or '').strip() and str(category.karat).strip() != karat:
        return jsonify({'error': f'عيار القطع ({karat}) يخالف عيار تصنيف «{category.name}» ({category.karat})'}), 400
    try:
        wage_per_gram = float(data.get('wage_per_gram') or 0.0)
        weights = [float(p.get('weight') or 0.0) for p in pieces]
    except (TypeError, ValueError):
        return jsonify({'error': 'وزن أو أجرة غير صالحة'}), 400
    if any(w <= 0 for w in weights):
        return jsonify({'error': 'لكل قطعة وزن أكبر من صفر'}), 400

    try:
        made = []
        for piece, weight in zip(pieces, weights):
            item = _new_item({
                'name': (piece.get('name') or '').strip() or base_name,
                'category_id': category.id if category else None,
                'karat': karat,
                'weight': weight,
                'count': 1,
                'stock': 1,
                'wage': round(wage_per_gram * weight, 2),
                'manufacturing_wage_per_gram': wage_per_gram,
                'description': (piece.get('description') or '').strip() or None,
                'has_stones': bool(data.get('has_stones', False)),
                'stones_weight': piece.get('stones_weight'),
                'stones_value': piece.get('stones_value'),
            })
            made.append(item)
        db.session.commit()
    except ValueError as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 400
    return jsonify({
        'message': f'تمت إضافة {len(made)} قطعة',
        'count': len(made),
        'items': [{'id': i.id, 'item_code': i.item_code, 'barcode': i.barcode, 'name': i.name,
                   'weight': i.weight} for i in made],
    }), 201


# Category Management Endpoints
@catalog_bp.route('/categories', methods=['GET'])
@require_permission('items.view')
def get_categories():
    """The categories offered -- the active ones; ?include_inactive=1 for all
    (the management dialog). A stopped category is offered to no one (ADR-045 B)."""
    q = Category.query
    if (request.args.get('include_inactive') or '').strip().lower() not in ('1', 'true', 'yes'):
        q = q.filter(Category.is_active.isnot(False))
    return jsonify([cat.to_dict() for cat in q.order_by(Category.name).all()])

@catalog_bp.route('/categories/<int:category_id>', methods=['GET'])
@require_permission('items.view')
def get_category(category_id):
    """Get a specific category"""
    category = Category.query.get_or_404(category_id)
    return jsonify(category.to_dict())


def _wage(raw):
    return float(raw) if raw not in (None, '', 0, '0') else None


@catalog_bp.route('/categories', methods=['POST'])
@require_permission('items.create')
def create_category():
    """A category: its karat required, its name in Latin digits ending in its
    karat (services.categories.canonical, the owner, 14 Oct 2026)."""
    from services.categories import canonical
    data = request.get_json() or {}
    try:
        name, karat = canonical(data.get('name'), data.get('karat'))
    except ValueError as e:
        return jsonify({'error': str(e)}), 400
    if Category.query.filter_by(name=name).first():
        return jsonify({'error': 'التصنيف موجود بالفعل'}), 409
    category = Category(name=name, description=data.get('description'), karat=karat,
                        default_wage=_wage(data.get('default_wage')))
    db.session.add(category)
    db.session.commit()
    return jsonify(category.to_dict()), 201

@catalog_bp.route('/categories/<int:category_id>', methods=['PUT'])
@require_permission('items.edit')
def update_category(category_id):
    """Rename, re-karat (only while unused -- its karat is fixed once used),
    describe, set its default wage, stop or restart it."""
    from services.categories import canonical, is_used
    category = Category.query.get_or_404(category_id)
    data = request.get_json() or {}
    karat = data.get('karat', category.karat)
    if 'karat' in data and str(data['karat']).strip() and str(data['karat']).strip() != str(category.karat or '').strip() \
            and is_used(category):
        return jsonify({'error': f'عيار «{category.name}» ثابت: التصنيف مستعمل في فواتير أو أصناف'}), 400
    try:
        name, karat = canonical(data.get('name') or category.name, karat)
    except ValueError as e:
        return jsonify({'error': str(e)}), 400
    if name != category.name and Category.query.filter(Category.name == name, Category.id != category_id).first():
        return jsonify({'error': 'التصنيف موجود بالفعل'}), 409
    category.name, category.karat = name, karat
    if 'description' in data:
        category.description = data['description']
    if 'default_wage' in data:
        category.default_wage = _wage(data['default_wage'])
    if 'is_active' in data:
        category.is_active = bool(data['is_active'])
    db.session.commit()
    return jsonify(category.to_dict())

@catalog_bp.route('/categories/<int:category_id>', methods=['DELETE'])
@require_permission('items.delete')
def delete_category(category_id):
    """Delete an unused category; a used one is stopped instead -- the delete
    counted items only, and 698 invoice lines met the foreign key."""
    from services.categories import is_used
    category = Category.query.get_or_404(category_id)
    if is_used(category):
        return jsonify({'error': f'«{category.name}» مستعمل في فواتير أو أصناف: أوقفه بدل حذفه'}), 409
    db.session.delete(category)
    db.session.commit()
    return jsonify({'message': 'تم حذف التصنيف بنجاح'})

@catalog_bp.route('/category-weight/balances', methods=['GET'])
@require_permission('items.view')
def category_weight_balances():
    """The stock by location and category (ADR-045 A2a): the one reader --
    the posted lines on stock safes and their allocations. The shape is the
    retired tracker's, which the report reads."""
    from services.stock_ledger import category_balances

    group_by_karat = (request.args.get('group_by_karat') or '').strip().lower() in ('1', 'true', 'yes', 'y', 'on')
    return jsonify(category_balances(
        safe_box_id=request.args.get('safe_box_id', type=int),
        category_id=request.args.get('category_id', type=int),
        karat=request.args.get('karat', type=float),
        group_by_karat=group_by_karat,
        gold_type=(request.args.get('gold_type') or '').strip() or None,
    ))

@catalog_bp.route('/category-weight/movements', methods=['GET'])
@require_permission('items.view')
def category_weight_movements():
    """The stock lines, newest first, split by category (ADR-045 A2a). The
    opening-balance route that wrote the retired tracker is gone (0 rows on
    the 12 Oct copy): the count writes the opening as an entry (A3)."""

    safe_box_id = request.args.get('safe_box_id', type=int)
    category_id = request.args.get('category_id', type=int)
    invoice_id = request.args.get('invoice_id', type=int)
    karat = request.args.get('karat', type=float)
    gold_type = (request.args.get('gold_type') or '').strip() or None
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    limit = request.args.get('limit', default=200, type=int)

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    if limit is None or limit <= 0:
        limit = 200
    limit = min(limit, 1000)

    from services.stock_ledger import stock_movements
    return jsonify(stock_movements(
        safe_box_id=safe_box_id, category_id=category_id, invoice_id=invoice_id, karat=karat,
        gold_type=gold_type, start=start_dt, end=end_dt, limit=limit,
    ))

# ── Pricing (gold price + costing) ────────────────────────────
# MOVED → backend/routes/pricing.py  (pricing_bp)
# ─────────────────────────────────────────────────────────────

# Invoices domain → routes/invoices.py (part 1)
# (GET /invoices/pending-post, GET /pending-actions, GET /invoices,
#  GET /invoices/<id>, PUT /invoices/<id>, DELETE /invoices/<id>,
#  PATCH /invoices/<id>/status, PATCH /invoices/<id>/reassign-employee,
#  POST /invoices/<id>/payments/<payment_id>/correct-method,
#  POST /invoices/<id>/approve, POST /invoices/<id>/reject,
#  POST /invoices/<id>/unpost, POST /invoices/<id>/payments)

