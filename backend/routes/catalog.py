"""Catalog domain routes — catalog_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, date, timedelta

from flask import Blueprint, g, jsonify, request
from sqlalchemy import func, and_, or_

from models import db, Category, Item
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
PURCHASE_ITEMS_CATEGORY_NAME = 'أصناف الشراء'

def _get_purchase_items_category(create_if_missing: bool = False):
    category = Category.query.filter_by(name=PURCHASE_ITEMS_CATEGORY_NAME).first()
    if category or not create_if_missing:
        return category

    category = Category(name=PURCHASE_ITEMS_CATEGORY_NAME, description='قائمة أصناف بسيطة خاصة بفواتير الشراء')
    db.session.add(category)
    db.session.commit()
    return category

@catalog_bp.route('/purchase-items', methods=['GET'])
@require_permission('items.view')
def get_purchase_items():
    """قائمة أصناف شراء مبسطة: الاسم + العيار (مع الاحتفاظ بالـ id/barcode للاستخدام الداخلي)"""
    category = _get_purchase_items_category(create_if_missing=False)
    if not category:
        return jsonify([])

    items = Item.query.filter(Item.category_id == category.id).order_by(Item.name.asc()).all()
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
    """إنشاء صنف شراء بسيط (اسم + عيار) داخل تصنيف أصناف الشراء."""
    data = request.get_json() or {}
    name = (data.get('name') or '').strip()
    if not name:
        return jsonify({'error': 'اسم الصنف مطلوب'}), 400

    karat = normalize_number(str(data.get('karat', '')))

    category = _get_purchase_items_category(create_if_missing=True)

    item_code = generate_item_code()
    barcode = generate_barcode_from_item_code(item_code)

    item = Item(
        item_code=item_code,
        name=name,
        barcode=barcode,
        category_id=category.id,
        karat=karat,
        weight=0.0,
        count=0,
        wage=0.0,
        manufacturing_wage_per_gram=0.0,
        description=data.get('description'),
        price=0.0,
        stock=0,
    )

    db.session.add(item)
    db.session.commit()

    return jsonify({
        'id': item.id,
        'item_code': item.item_code,
        'name': item.name,
        'barcode': item.barcode,
        'karat': item.karat,
        'category_id': item.category_id,
        'category_name': item.category.name if item.category else None,
    }), 201

@catalog_bp.route('/purchase-items/<int:item_id>', methods=['DELETE'])
@require_permission('items.delete')
def delete_purchase_item(item_id):
    category = _get_purchase_items_category(create_if_missing=False)
    if not category:
        return jsonify({'error': 'تصنيف أصناف الشراء غير موجود'}), 404

    item = Item.query.get_or_404(item_id)
    if item.category_id != category.id:
        return jsonify({'error': 'لا يمكن حذف هذا الصنف من قائمة أصناف الشراء'}), 400

    db.session.delete(item)
    db.session.commit()
    return jsonify({'result': 'success'})

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
        # توليد item_code تلقائياً
        item_code = data.get('item_code')
        if not item_code:
            item_code = generate_item_code()
        else:
            # التحقق من صحة الكود المدخل
            validation = validate_item_code(item_code)
            if not validation['is_valid']:
                return jsonify({'error': validation['message']}), 400
        
        # توليد barcode إذا لم يُدخل
        barcode = data.get('barcode')
        if not barcode:
            barcode = generate_barcode_from_item_code(item_code)
        
        item = Item(
            item_code=item_code,
            name=data['name'],
            barcode=barcode,
            category_id=data.get('category_id'),
            karat=normalize_number(str(data.get('karat', ''))),
            weight=normalize_number(str(data.get('weight', ''))),
            count=normalize_number(str(data.get('count', ''))),
            wage=normalize_number(str(data.get('wage', ''))),
            manufacturing_wage_per_gram=normalize_number(str(data.get('manufacturing_wage_per_gram', 0))),
            description=data.get('description'),
            price=normalize_number(str(data.get('price', 0))),
            stock=normalize_number(str(data.get('stock', 0)))
        )
        db.session.add(item)
        db.session.commit()
        return jsonify({
            'id': item.id,
            'item_code': item.item_code,
            'barcode': item.barcode
        }), 201
        
    except Exception as e:
        db.session.rollback()
        # تحقق من خطأ التكرار
        if 'item_code' in str(e):
            return jsonify({'error': f'كود الصنف {item_code} مستخدم بالفعل'}), 409
        if 'barcode' in str(e):
            return jsonify({'error': f'الباركود {barcode} مستخدم بالفعل'}), 409
        return jsonify({'error': str(e)}), 500

# Category Management Endpoints
@catalog_bp.route('/categories', methods=['GET'])
@require_permission('items.view')
def get_categories():
    """Get all categories"""
    categories = Category.query.order_by(Category.name).all()
    return jsonify([cat.to_dict() for cat in categories])

@catalog_bp.route('/categories/<int:category_id>', methods=['GET'])
@require_permission('items.view')
def get_category(category_id):
    """Get a specific category"""
    category = Category.query.get_or_404(category_id)
    return jsonify(category.to_dict())

@catalog_bp.route('/categories', methods=['POST'])
@require_permission('items.create')
def create_category():
    """Create a new category"""
    try:
        data = request.get_json()
        
        if not data or not data.get('name'):
            return jsonify({'error': 'اسم التصنيف مطلوب'}), 400
        
        # Check if category already exists
        existing = Category.query.filter_by(name=data['name']).first()
        if existing:
            return jsonify({'error': 'التصنيف موجود بالفعل'}), 409
        
        default_wage_raw = data.get('default_wage')
        default_wage = float(default_wage_raw) if default_wage_raw not in (None, '', 0, '0') else None

        category = Category(
            name=data['name'],
            description=data.get('description'),
            karat=data.get('karat'),
            default_wage=default_wage,
        )
        
        db.session.add(category)
        db.session.commit()
        
        return jsonify(category.to_dict()), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@catalog_bp.route('/categories/<int:category_id>', methods=['PUT'])
@require_permission('items.edit')
def update_category(category_id):
    """Update a category"""
    try:
        category = Category.query.get_or_404(category_id)
        data = request.get_json()
        
        if 'name' in data and data['name']:
            # Check if new name already exists (excluding current category)
            existing = Category.query.filter(
                Category.name == data['name'],
                Category.id != category_id
            ).first()
            if existing:
                return jsonify({'error': 'التصنيف موجود بالفعل'}), 409
            
            category.name = data['name']
        
        if 'description' in data:
            category.description = data['description']
        
        if 'karat' in data:
            category.karat = data['karat']

        if 'default_wage' in data:
            raw = data['default_wage']
            category.default_wage = float(raw) if raw not in (None, '', 0, '0') else None

        db.session.commit()
        return jsonify(category.to_dict())
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@catalog_bp.route('/categories/<int:category_id>', methods=['DELETE'])
@require_permission('items.delete')
def delete_category(category_id):
    """Delete a category"""
    try:
        category = Category.query.get_or_404(category_id)
        
        # Check if category has items
        if len(category.items) > 0:
            return jsonify({
                'error': f'لا يمكن حذف التصنيف لأنه مرتبط بـ {len(category.items)} صنف'
            }), 400
        
        db.session.delete(category)
        db.session.commit()
        
        return jsonify({'message': 'تم حذف التصنيف بنجاح'})
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

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

