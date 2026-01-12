"""
Payment Methods Routes
وسائل الدفع API endpoints
"""
import json
from typing import Any, Dict, List

from flask import Blueprint, request, jsonify
from sqlalchemy.exc import IntegrityError
from models import (
    db,
    Account,
    PaymentMethod,
    PaymentType,
    PAYMENT_METHOD_ALLOWED_INVOICE_TYPES,
    SafeBox,
    Settings,
)


INVOICE_TYPE_OPTIONS = [
    {
        'value': 'بيع',
        'name_ar': 'فاتورة بيع',
        'category': 'pos',
        'description': 'بيع ذهب جديد للعميل',
    },
    {
        'value': 'شراء من عميل',
        'name_ar': 'شراء كسر من عميل',
        'category': 'pos',
        'description': 'شراء ذهب كسر من العميل',
    },
    {
        'value': 'تسكير من مكتب',
        'name_ar': 'تسكير من مكتب',
        'category': 'offices',
        'description': 'شراء ذهب من مكتب التسكير (الذهب يبقى أمانة عند المكتب)',
    },
    {
        'value': 'مرتجع بيع',
        'name_ar': 'مرتجع بيع',
        'category': 'pos',
        'description': 'استرجاع فاتورة بيع من العميل',
    },
    {
        'value': 'مرتجع شراء',
        'name_ar': 'مرتجع شراء كسر',
        'category': 'pos',
        'description': 'استرجاع مشتريات الكسر من العميل',
    },
    {
        'value': 'شراء',
        'name_ar': 'شراء',
        'category': 'accounting',
        'description': 'شراء ذهب جديد من المورد',
    },
    {
        'value': 'مرتجع شراء (مورد)',
        'name_ar': 'مرتجع شراء (مورد)',
        'category': 'accounting',
        'description': 'استرجاع مشتريات من المورد',
    },
]


def _canonicalize_invoice_type(value: str) -> str:
    """Normalize invoice types to the canonical labels used by the app.

    We intentionally avoid relying on exact legacy strings; instead we infer
    supplier purchase/return by keywords to support older stored values.
    """
    candidate = (value or '').strip()
    if not candidate:
        return candidate

    if 'مورد' in candidate and 'شراء' in candidate:
        if 'مرتجع' in candidate:
            return 'مرتجع شراء (مورد)'
        return 'شراء'

    return candidate


def _normalize_invoice_type_filter(raw_value):
    if not raw_value:
        return None

    cleaned = _canonicalize_invoice_type(raw_value)
    if cleaned in {'الكل', 'all', 'ALL'}:
        return None

    if cleaned not in PAYMENT_METHOD_ALLOWED_INVOICE_TYPES:
        raise ValueError('نوع فاتورة غير مدعوم')

    return cleaned


def _normalize_applicable_invoice_types(raw_types):
    if raw_types is None:
        return list(PAYMENT_METHOD_ALLOWED_INVOICE_TYPES)

    if isinstance(raw_types, str):
        if raw_types.strip() in {'الكل', 'all', 'ALL'}:
            return list(PAYMENT_METHOD_ALLOWED_INVOICE_TYPES)
        raw_types = [raw_types]

    if not isinstance(raw_types, list) or len(raw_types) == 0:
        raise ValueError('يجب اختيار نوع فاتورة واحد على الأقل')

    normalized = []
    invalid = []

    for raw_type in raw_types:
        if isinstance(raw_type, str):
            candidate = _canonicalize_invoice_type(raw_type)
        else:
            candidate = None

        if not candidate or candidate not in PAYMENT_METHOD_ALLOWED_INVOICE_TYPES:
            invalid.append(str(raw_type))
            continue

        if candidate not in normalized:
            normalized.append(candidate)

    if invalid:
        raise ValueError(f"أنواع فواتير غير مدعومة: {', '.join(invalid)}")

    return normalized


def _filter_payment_methods_by_invoice_type(payment_methods, invoice_type):
    if not invoice_type:
        return payment_methods

    filtered = []
    for method in payment_methods:
        applicable = method.applicable_invoice_types
        if not applicable:
            filtered.append(method)
            continue
        if invoice_type in applicable:
            filtered.append(method)
    return filtered

LEGACY_FALLBACK_PAYMENT_METHODS: List[Dict[str, Any]] = [
    {
        'name': 'نقداً',
        'payment_type': 'cash',
        'commission_rate': 0.0,
        'settlement_days': 0,
        'display_order': 1,
    },
    {
        'name': 'بطاقة',
        'payment_type': 'mada',
        'commission_rate': 2.5,
        'settlement_days': 2,
        'display_order': 2,
    },
    {
        'name': 'تحويل',
        'payment_type': 'bank_transfer',
        'commission_rate': 0.0,
        'settlement_days': 1,
        'display_order': 3,
    },
    {
        'name': 'آجل',
        'payment_type': 'credit',
        'commission_rate': 0.0,
        'settlement_days': 0,
        'display_order': 4,
    },
]

payment_methods_api = Blueprint('payment_methods_api', __name__)


def _infer_payment_type_from_name(name: str) -> str:
    normalized = (name or '').lower()
    if any(keyword in normalized for keyword in ['cash', 'نقد']):
        return 'cash'
    if any(keyword in normalized for keyword in ['mada', 'مدى']):
        return 'mada'
    if any(keyword in normalized for keyword in ['visa', 'فيزا']):
        return 'visa'
    if any(keyword in normalized for keyword in ['master', 'ماستر']):
        return 'mastercard'
    if any(keyword in normalized for keyword in ['stc', 'ستc']):
        return 'stc_pay'
    if any(keyword in normalized for keyword in ['apple', 'ابل']):
        return 'apple_pay'
    if any(keyword in normalized for keyword in ['tabby', 'تابي']):
        return 'tabby'
    if any(keyword in normalized for keyword in ['tamara', 'تمارا']):
        return 'tamara'
    if any(keyword in normalized for keyword in ['bank', 'تحويل', 'حوالة']):
        return 'bank_transfer'
    if any(keyword in normalized for keyword in ['آجل', 'اجل', 'credit']):
        return 'credit'
    slug = ''.join(ch if ch.isalnum() else '_' for ch in normalized)
    slug = slug.strip('_') or 'custom'
    return f'custom_{slug}'[:50]


def _load_legacy_payment_methods() -> List[Dict[str, Any]]:
    settings_record = Settings.query.first()
    legacy_methods: List[Dict[str, Any]] = []

    if settings_record and settings_record.payment_methods:
        try:
            decoded = json.loads(settings_record.payment_methods)
            if isinstance(decoded, list):
                legacy_methods = [
                    method for method in decoded if isinstance(method, dict)
                ]
        except (ValueError, TypeError):
            legacy_methods = []

    if not legacy_methods:
        legacy_methods = LEGACY_FALLBACK_PAYMENT_METHODS.copy()

    return legacy_methods


def _normalize_applicable_types(raw_value: Any) -> List[str]:
    if isinstance(raw_value, list) and raw_value:
        filtered = [
            str(value)
            for value in raw_value
            if isinstance(value, str) and value in PAYMENT_METHOD_ALLOWED_INVOICE_TYPES
        ]
        if filtered:
            return filtered
    return list(PAYMENT_METHOD_ALLOWED_INVOICE_TYPES)


def _sync_payment_methods_from_settings() -> None:
    legacy_methods = _load_legacy_payment_methods()
    if not legacy_methods:
        return

    changed = False
    seen_ids: List[int] = []

    for index, legacy in enumerate(legacy_methods):
        name = str(legacy.get('name') or f'وسيلة دفع {index + 1}')
        payment_type = legacy.get('payment_type') or _infer_payment_type_from_name(name)

        commission_value = legacy.get('commission_rate', legacy.get('commission', 0))
        settlement_days = legacy.get('settlement_days', 0)
        display_order = legacy.get('display_order', index + 1)
        is_active = bool(legacy.get('is_active', True))
        applicable_types = _normalize_applicable_types(
            legacy.get('applicable_invoice_types')
        )
        default_safe_box_id = legacy.get('default_safe_box_id')

        payment_method = None
        created = False
        legacy_id = legacy.get('id')
        if isinstance(legacy_id, int):
            payment_method = PaymentMethod.query.get(legacy_id)

        if not payment_method and payment_type:
            payment_method = PaymentMethod.query.filter_by(payment_type=payment_type).first()

        if not payment_method:
            payment_method = PaymentMethod.query.filter_by(name=name).first()

        if not payment_method:
            payment_method = PaymentMethod(
                payment_type=payment_type,
                name=name,
            )
            db.session.add(payment_method)
            created = True
            changed = True

        # IMPORTANT: do not overwrite existing DB values on every GET.
        # Sync should only populate missing payment methods (initial migration/fallback).
        if created:
            update_fields = {
                'name': name,
                'payment_type': payment_type,
                'commission_rate': float(commission_value or 0.0),
                'settlement_days': int(settlement_days or 0),
                'display_order': int(display_order or (index + 1)),
                'is_active': is_active,
                'default_safe_box_id': default_safe_box_id,
            }

            for attr, value in update_fields.items():
                if getattr(payment_method, attr) != value:
                    setattr(payment_method, attr, value)
                    changed = True

            payment_method.applicable_invoice_types = applicable_types
            changed = True
        elif payment_method.applicable_invoice_types is None:
            payment_method.applicable_invoice_types = applicable_types
            changed = True

        seen_ids.append(payment_method.id or 0)

    if changed:
        db.session.commit()

def generate_payment_method_account_number(parent_account_id):
    """
    توليد رقم حساب لوسيلة دفع جديدة
    مثال: parent_account_number = '1020'
    الناتج: '1020.1', '1020.2', إلخ
    """
    parent = Account.query.get(parent_account_id)
    if not parent:
        return None
    
    parent_number = parent.account_number
    
    # البحث عن آخر رقم فرعي
    children = Account.query.filter(
        Account.parent_id == parent_account_id,
        Account.account_number.like(f'{parent_number}.%')
    ).all()
    
    if not children:
        return f'{parent_number}.1'
    
    # استخراج الأرقام بعد النقطة
    max_suffix = 0
    for child in children:
        parts = child.account_number.split('.')
        if len(parts) == 2 and parts[1].isdigit():
            suffix = int(parts[1])
            max_suffix = max(max_suffix, suffix)
    
    return f'{parent_number}.{max_suffix + 1}'

@payment_methods_api.route('/payment-methods', methods=['GET'])
def get_payment_methods():
    """جلب جميع وسائل الدفع"""
    try:
        _sync_payment_methods_from_settings()
        invoice_type_filter = request.args.get('invoice_type')

        try:
            invoice_type_filter = _normalize_invoice_type_filter(invoice_type_filter)
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        payment_methods = PaymentMethod.query.all()
        payment_methods = _filter_payment_methods_by_invoice_type(payment_methods, invoice_type_filter)
        return jsonify([pm.to_dict() for pm in payment_methods]), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods/active', methods=['GET'])
def get_active_payment_methods():
    """جلب وسائل الدفع النشطة فقط"""
    try:
        _sync_payment_methods_from_settings()
        invoice_type_filter = request.args.get('invoice_type')

        try:
            invoice_type_filter = _normalize_invoice_type_filter(invoice_type_filter)
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        payment_methods = PaymentMethod.query.filter_by(is_active=True).all()
        payment_methods = _filter_payment_methods_by_invoice_type(payment_methods, invoice_type_filter)
        return jsonify([pm.to_dict() for pm in payment_methods]), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods', methods=['POST'])
def create_payment_method():
    """إضافة وسيلة دفع جديدة"""
    try:
        data = request.get_json()
        
        # 🆕 دعم النظام الجديد (default_safe_box_id) والقديم (parent_account_id)
        default_safe_box_id = data.get('default_safe_box_id')
        parent_account_id = data.get('parent_account_id')
        
        # التحقق من البيانات المطلوبة
        required_fields = ['payment_type', 'name']
        for field in required_fields:
            if field not in data:
                return jsonify({'error': f'الحقل {field} مطلوب'}), 400
        
        # 🆕 الخزينة والحساب اختياريان الآن
        # سيتم اختيار الخزينة عند إنشاء الفاتورة
        account_id_to_use = None
        
        # التحقق من وجود الخزينة إذا تم تحديدها
        if default_safe_box_id:
            safe_box = SafeBox.query.get(default_safe_box_id)
            if not safe_box:
                return jsonify({'error': 'الخزينة غير موجودة'}), 404
            # استخدام حساب الخزينة (اختياري)
            account_id_to_use = safe_box.account_id
        
        try:
            applicable_invoice_types = _normalize_applicable_invoice_types(
                data.get('applicable_invoice_types')
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400
        
        # إنشاء وسيلة الدفع
        try:
            payment_method = PaymentMethod(
                payment_type=data['payment_type'],
                name=data['name'],
                commission_rate=data.get('commission_rate', 0.0),
                settlement_days=data.get('settlement_days', 0),
                is_active=data.get('is_active', True),
                applicable_invoice_types=applicable_invoice_types,
                default_safe_box_id=default_safe_box_id  # اختياري
            )
        except TypeError as exc:
            db.session.rollback()
            message = str(exc)
            outdated_keywords = {'applicable_invoice_types', 'parent_account_id'}
            if any(keyword in message for keyword in outdated_keywords):
                return jsonify({
                    'error': 'الخادم يعمل على نسخة قديمة من الكود. يرجى إعادة تشغيل السيرفر بعد سحب آخر التحديثات وتشغيل الترحيلات (alembic upgrade head).'
                }), 500
            raise

        db.session.add(payment_method)
        db.session.commit()
        
        return jsonify({
            'message': 'تم إضافة وسيلة الدفع بنجاح',
            'payment_method': payment_method.to_dict()
        }), 201
        
    except IntegrityError as e:
        db.session.rollback()
        return jsonify({'error': 'رقم الحساب موجود مسبقاً'}), 409
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods/<int:id>', methods=['PUT'])
def update_payment_method(id):
    """تعديل وسيلة دفع"""
    try:
        payment_method = PaymentMethod.query.get(id)
        
        if not payment_method:
            return jsonify({'error': 'وسيلة الدفع غير موجودة'}), 404
        
        data = request.get_json()
        
        # تحديث البيانات
        if 'payment_type' in data:
            new_payment_type = data['payment_type']

            parent_account_id = None
            if payment_method.default_safe_box and payment_method.default_safe_box.account:
                parent_account_id = payment_method.default_safe_box.account.parent_id

            if parent_account_id:
                duplicate_for_update = (
                    PaymentMethod.query
                    .join(SafeBox, PaymentMethod.default_safe_box_id == SafeBox.id)
                    .join(Account, SafeBox.account_id == Account.id)
                    .filter(
                        PaymentMethod.payment_type == new_payment_type,
                        Account.parent_id == parent_account_id,
                        PaymentMethod.id != payment_method.id
                    )
                    .first()
                )

                if duplicate_for_update:
                    return jsonify({'error': 'هذا النوع من وسائل الدفع مرتبط بالفعل بنفس الحساب الأب'}), 400

            payment_method.payment_type = new_payment_type
        if 'name' in data:
            payment_method.name = data['name']
        if 'commission_rate' in data:
            payment_method.commission_rate = data['commission_rate']
        if 'is_active' in data:
            payment_method.is_active = data['is_active']
        if 'applicable_invoice_types' in data:
            try:
                payment_method.applicable_invoice_types = _normalize_applicable_invoice_types(
                    data.get('applicable_invoice_types')
                )
            except ValueError as exc:
                return jsonify({'error': str(exc)}), 400
        
        db.session.commit()
        
        return jsonify({
            'message': 'تم تحديث وسيلة الدفع بنجاح',
            'payment_method': payment_method.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods/<int:id>', methods=['DELETE'])
def delete_payment_method(id):
    """حذف وسيلة دفع"""
    try:
        payment_method = PaymentMethod.query.get(id)
        
        if not payment_method:
            return jsonify({'error': 'وسيلة الدفع غير موجودة'}), 404
        
        # لا نحذف الخزينة لأنها قد تكون مستخدمة بوسائل دفع أخرى
        # فقط نحذف وسيلة الدفع نفسها
        db.session.delete(payment_method)
        db.session.commit()
        
        return jsonify({'message': 'تم حذف وسيلة الدفع بنجاح'}), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods/update-order', methods=['PUT'])
def update_payment_methods_order():
    """تحديث ترتيب طرق الدفع"""
    try:
        data = request.get_json()
        methods = data.get('methods', [])
        
        if not methods:
            return jsonify({'error': 'لا توجد طرق دفع للتحديث'}), 400
        
        # تحديث display_order لكل طريقة
        for method_data in methods:
            method_id = method_data.get('id')
            display_order = method_data.get('display_order')
            
            if method_id and display_order is not None:
                payment_method = PaymentMethod.query.get(method_id)
                if payment_method:
                    payment_method.display_order = display_order
        
        db.session.commit()
        
        return jsonify({'message': 'تم تحديث الترتيب بنجاح'}), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods/bank-accounts', methods=['GET'])
def get_bank_accounts_for_payment_methods():
    """جلب الحسابات المتاحة لربط وسائل الدفع (النقدية وما في حكمها)"""
    try:
        # جلب جميع الحسابات التي تبدأ برقم 10 (النقدية وما في حكمها)
        # أو الحسابات ذات النوع المحدد
        eligible_types = ['bank_account', 'cash', 'digital_wallet', 'receivable']

        # جلب الحسابات بناءً على النوع أو رقم الحساب (يبدأ بـ 10)
        available_accounts = Account.query.filter(
            db.or_(
                Account.account_type.in_(eligible_types),
                Account.account_number.like('10%')
            )
        ).order_by(Account.account_number).all()
        
        # تصفية الحسابات لإزالة الحسابات الفرعية لوسائل الدفع
        filtered_accounts = [
            acc for acc in available_accounts 
            if acc.account_type != 'payment_method'
        ]
        
        return jsonify([{
            'id': acc.id,
            'account_number': acc.account_number,
            'name': acc.name,
            'account_type': acc.account_type if acc.account_type else 'cash',
            'bank_name': acc.bank_name if acc.bank_name else ''
        } for acc in filtered_accounts]), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@payment_methods_api.route('/payment-methods/invoice-types', methods=['GET'])
def get_invoice_type_options():
    """جلب أنواع الفواتير المسموح بها لوسائل الدفع"""
    try:
        return jsonify({
            'options': INVOICE_TYPE_OPTIONS,
            'default_selection': PAYMENT_METHOD_ALLOWED_INVOICE_TYPES,
        }), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@payment_methods_api.route('/payment-types', methods=['GET'])
def get_payment_types():
    """جلب أنواع وسائل الدفع المتاحة (ديناميكي)"""
    try:
        payment_types = PaymentType.query.filter_by(is_active=True).order_by(PaymentType.sort_order).all()
        return jsonify([pt.to_dict() for pt in payment_types]), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@payment_methods_api.route('/payment-types', methods=['POST'])
def create_payment_type():
    """إضافة نوع وسيلة دفع جديد"""
    try:
        data = request.get_json()
        
        # التحقق من عدم وجود code مكرر
        existing = PaymentType.query.filter_by(code=data['code']).first()
        if existing:
            return jsonify({'error': 'كود وسيلة الدفع موجود مسبقاً'}), 400
        
        payment_type = PaymentType(
            code=data['code'],
            name_ar=data['name_ar'],
            name_en=data.get('name_en'),
            icon=data.get('icon', '💳'),
            category=data.get('category', 'card'),
            sort_order=data.get('sort_order', 0)
        )
        
        db.session.add(payment_type)
        db.session.commit()
        
        return jsonify(payment_type.to_dict()), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@payment_methods_api.route('/payment-types/<int:id>', methods=['DELETE'])
def delete_payment_type(id):
    """حذف نوع وسيلة دفع"""
    try:
        payment_type = PaymentType.query.get_or_404(id)
        
        # التحقق من عدم استخدامه في وسائل دفع
        used_count = PaymentMethod.query.filter_by(payment_type=payment_type.code).count()
        if used_count > 0:
            return jsonify({'error': f'لا يمكن الحذف - يوجد {used_count} وسيلة دفع تستخدم هذا النوع'}), 400
        
        db.session.delete(payment_type)
        db.session.commit()
        
        return jsonify({'message': 'تم الحذف بنجاح'}), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500
