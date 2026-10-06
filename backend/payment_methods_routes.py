"""
Payment Methods Routes
وسائل الدفع API endpoints
"""
import json
from typing import Any, Dict, List

from flask import Blueprint, request, jsonify
from auth_decorators import require_permission
from sqlalchemy.exc import IntegrityError
from models import (
    db,
    Account,
    PaymentMethod,
    PaymentType,
    Invoice,
    InvoicePayment,
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


def _normalize_commission_timing(raw_value: Any) -> str:
    if raw_value is None:
        return 'invoice'
    value = str(raw_value).strip().lower()
    if not value:
        return 'invoice'
    if value in {'invoice', 'settlement'}:
        return value
    raise ValueError('قيمة commission_timing غير مدعومة (invoice أو settlement)')


def _normalize_settlement_schedule_type(raw_value: Any) -> str:
    if raw_value is None:
        return 'days'
    value = str(raw_value).strip().lower()
    if not value:
        return 'days'
    if value in {'days', 'weekday'}:
        return value
    raise ValueError('قيمة settlement_schedule_type غير مدعومة (days أو weekday)')


def _normalize_deposit_schedule_type(raw_value: Any) -> str:
    if raw_value is None:
        return 'days'
    value = str(raw_value).strip().lower()
    if not value:
        return 'days'
    if value in {'days', 'weekday'}:
        return value
    raise ValueError('قيمة deposit_schedule_type غير مدعومة (days أو weekday)')


def _normalize_weekday(raw_value: Any):
    # allow 0 (الاثنين) — do not treat it as falsy/null
    if raw_value is None:
        return None
    if isinstance(raw_value, str) and raw_value.strip() == '':
        return None
    try:
        weekday = int(raw_value)
    except Exception:
        raise ValueError('قيمة settlement_weekday غير صالحة')
    if weekday < 0 or weekday > 6:
        raise ValueError('قيمة settlement_weekday يجب أن تكون بين 0 و 6')
    return weekday


DEFAULT_PAYMENT_TYPE_DEFINITIONS: List[Dict[str, Any]] = [
    {
        'code': 'cash',
        'name_ar': 'نقداً',
        'name_en': 'Cash',
        'icon': '💵',
        'category': 'cash',
        'sort_order': 1,
    },
    {
        'code': 'mada',
        'name_ar': 'بطاقة مدى',
        'name_en': 'Mada',
        'icon': '💳',
        'category': 'card',
        'sort_order': 2,
    },
    {
        'code': 'visa',
        'name_ar': 'بطاقة فيزا',
        'name_en': 'Visa',
        'icon': '💳',
        'category': 'card',
        'sort_order': 3,
    },
    {
        'code': 'mastercard',
        'name_ar': 'بطاقة ماستركارد',
        'name_en': 'Mastercard',
        'icon': '💳',
        'category': 'card',
        'sort_order': 4,
    },
    {
        'code': 'stc_pay',
        'name_ar': 'STC Pay',
        'name_en': 'STC Pay',
        'icon': '📱',
        'category': 'digital_wallet',
        'sort_order': 5,
    },
    {
        'code': 'apple_pay',
        'name_ar': 'Apple Pay',
        'name_en': 'Apple Pay',
        'icon': '📱',
        'category': 'digital_wallet',
        'sort_order': 6,
    },
    {
        'code': 'tabby',
        'name_ar': 'تابي',
        'name_en': 'Tabby',
        'icon': '🛍️',
        'category': 'bnpl',
        'sort_order': 7,
    },
    {
        'code': 'tamara',
        'name_ar': 'تمارا',
        'name_en': 'Tamara',
        'icon': '🛍️',
        'category': 'bnpl',
        'sort_order': 8,
    },
    {
        'code': 'bank_transfer',
        'name_ar': 'تحويل بنكي',
        'name_en': 'Bank Transfer',
        'icon': '🏦',
        'category': 'bank_transfer',
        'sort_order': 9,
    },
]


def ensure_default_payment_types() -> None:
    """Ensure a usable set of payment types exists.

    This keeps the app functional even if the database was created without
    running the optional seeding scripts.
    """

    try:
        existing = {
            pt.code: pt
            for pt in PaymentType.query.all()
            if getattr(pt, 'code', None)
        }
    except Exception:
        return

    changed = False

    for definition in DEFAULT_PAYMENT_TYPE_DEFINITIONS:
        code = str(definition.get('code') or '').strip()
        if not code:
            continue

        record = existing.get(code)
        if record is None:
            record = PaymentType(
                code=code,
                name_ar=str(definition.get('name_ar') or code),
                name_en=definition.get('name_en'),
                icon=definition.get('icon'),
                category=definition.get('category'),
                is_active=True,
                sort_order=int(definition.get('sort_order') or 0),
            )
            db.session.add(record)
            existing[code] = record
            changed = True
            continue

        # Preserve any existing customization; only fill missing fields.
        if not getattr(record, 'name_ar', None):
            record.name_ar = str(definition.get('name_ar') or code)
            changed = True
        if getattr(record, 'name_en', None) in (None, '') and definition.get('name_en'):
            record.name_en = definition.get('name_en')
            changed = True
        if getattr(record, 'icon', None) in (None, '') and definition.get('icon'):
            record.icon = definition.get('icon')
            changed = True
        if getattr(record, 'category', None) in (None, '') and definition.get('category'):
            record.category = definition.get('category')
            changed = True
        if getattr(record, 'sort_order', None) in (None, 0) and definition.get('sort_order'):
            record.sort_order = int(definition.get('sort_order') or 0)
            changed = True

    if changed:
        try:
            db.session.commit()
        except Exception:
            db.session.rollback()


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

    # If settings explicitly provide a JSON list (even an empty one), honor it.
    # This allows admin tooling (like WIPE-ALL) to intentionally disable legacy auto-seeding
    # by setting Settings.payment_methods to "[]".
    if settings_record and settings_record.payment_methods is not None:
        raw_value = settings_record.payment_methods
        if not raw_value or not str(raw_value).strip():
            return []
        try:
            decoded = json.loads(raw_value)
            if isinstance(decoded, list):
                return [method for method in decoded if isinstance(method, dict)]
        except (ValueError, TypeError):
            legacy_methods = []

    # Backward-compatible fallback: if settings are missing/invalid, seed from defaults.
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
        fixed_commission_value = legacy.get(
            'commission_fixed_amount',
            legacy.get('fixed_commission_amount', legacy.get('fixed_commission', 0)),
        )
        settlement_days = legacy.get('settlement_days', 0)
        display_order = legacy.get('display_order', index + 1)
        is_active = bool(legacy.get('is_active', True))
        applicable_types = _normalize_applicable_types(
            legacy.get('applicable_invoice_types')
        )
        default_safe_box_id = legacy.get('default_safe_box_id')
        try:
            legacy_commission_timing = _normalize_commission_timing(
                legacy.get('commission_timing')
            )
        except ValueError:
            legacy_commission_timing = 'invoice'

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
                'commission_fixed_amount': float(fixed_commission_value or 0.0),
                'commission_timing': legacy_commission_timing,
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
        else:
            # Keep existing rows in sync for critical numeric knobs.
            # This is important for legacy Settings-driven deployments where Settings is the source of truth.
            try:
                desired_commission = float(commission_value or 0.0)
            except Exception:
                desired_commission = 0.0

            try:
                desired_fixed_commission = float(fixed_commission_value or 0.0)
            except Exception:
                desired_fixed_commission = 0.0

            if float(getattr(payment_method, 'commission_rate', 0.0) or 0.0) != desired_commission:
                payment_method.commission_rate = desired_commission
                changed = True

            if float(getattr(payment_method, 'commission_fixed_amount', 0.0) or 0.0) != desired_fixed_commission:
                payment_method.commission_fixed_amount = desired_fixed_commission
                changed = True

        if payment_method.applicable_invoice_types is None:
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
@require_permission('business.setup')
def create_payment_method():
    """إضافة وسيلة دفع جديدة"""
    try:
        data = request.get_json()
        
        # 🆕 دعم النظام الجديد (default_safe_box_id) والقديم (parent_account_id)
        default_safe_box_id = data.get('default_safe_box_id')
        parent_account_id = data.get('parent_account_id')

        # 🆕 إعدادات التسوية التلقائية
        auto_settlement_enabled = bool(data.get('auto_settlement_enabled', False))
        try:
            settlement_schedule_type = _normalize_settlement_schedule_type(
                data.get('settlement_schedule_type')
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400
        try:
            settlement_weekday = _normalize_weekday(data.get('settlement_weekday'))
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400
        settlement_bank_safe_box_id = data.get('settlement_bank_safe_box_id')
        if settlement_bank_safe_box_id in (None, '', 0, '0', False):
            settlement_bank_safe_box_id = None
        
        # التحقق من البيانات المطلوبة
        required_fields = ['payment_type', 'name']
        for field in required_fields:
            if field not in data:
                return jsonify({'error': f'الحقل {field} مطلوب'}), 400
        
        # 🆕 الخزينة والحساب اختياريان الآن
        # سيتم اختيار الخزينة عند إنشاء الفاتورة
        account_id_to_use = None
        
        safe_box = None

        # التحقق من وجود الخزينة إذا تم تحديدها
        if default_safe_box_id:
            safe_box = SafeBox.query.get(default_safe_box_id)
            if not safe_box:
                return jsonify({'error': 'الخزينة غير موجودة'}), 404

            # منع ربط وسيلة دفع بخزينة ذهب
            try:
                if (safe_box.safe_type or '').strip().lower() == 'gold':
                    return jsonify({'error': 'لا يمكن ربط وسيلة دفع بخزينة ذهب'}), 400
            except Exception:
                pass

            # استخدام حساب الخزينة (اختياري)
            account_id_to_use = safe_box.account_id

        # Validate auto settlement bank safe box
        if settlement_bank_safe_box_id is not None:
            try:
                settlement_bank_safe_box_id = int(settlement_bank_safe_box_id)
            except Exception:
                return jsonify({'error': 'معرف الخزينة البنكية غير صالح'}), 400
            bank_sb = SafeBox.query.get(settlement_bank_safe_box_id)
            if not bank_sb:
                return jsonify({'error': 'الخزينة البنكية غير موجودة'}), 404
            try:
                if (bank_sb.safe_type or '').strip().lower() != 'bank':
                    return jsonify({'error': 'يجب اختيار خزينة من نوع بنك للتسوية التلقائية'}), 400
            except Exception:
                return jsonify({'error': 'يجب اختيار خزينة من نوع بنك للتسوية التلقائية'}), 400

        # If enabled, ensure required fields exist
        if auto_settlement_enabled:
            if not default_safe_box_id:
                return jsonify({'error': 'يجب تحديد خزينة مستحقات (clearing) لتمكين التسوية التلقائية'}), 400
            try:
                if safe_box and (safe_box.safe_type or '').strip().lower() != 'clearing':
                    return jsonify({'error': 'يجب أن تكون الخزينة الافتراضية من نوع مستحقات تحصيل (clearing)'}), 400
            except Exception:
                return jsonify({'error': 'يجب أن تكون الخزينة الافتراضية من نوع مستحقات تحصيل (clearing)'}), 400
            if settlement_bank_safe_box_id is None:
                return jsonify({'error': 'يجب تحديد خزينة بنكية لتمكين التسوية التلقائية'}), 400
            if settlement_schedule_type == 'weekday' and settlement_weekday is None:
                return jsonify({'error': 'يجب تحديد يوم الأسبوع عند اختيار جدول (weekday)'}), 400
        
        try:
            applicable_invoice_types = _normalize_applicable_invoice_types(
                data.get('applicable_invoice_types')
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        try:
            commission_timing = _normalize_commission_timing(
                data.get('commission_timing')
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        # عمولة ثابتة لكل عملية (اختياري)
        commission_fixed_amount = 0.0
        if 'commission_fixed_amount' in data and data.get('commission_fixed_amount') not in (None, '', False):
            try:
                commission_fixed_amount = float(data.get('commission_fixed_amount') or 0.0)
            except Exception:
                return jsonify({'error': 'قيمة العمولة الثابتة غير صالحة'}), 400
            if commission_fixed_amount < 0:
                return jsonify({'error': 'لا يمكن أن تكون العمولة الثابتة سالبة'}), 400
        
        # حساب مصروف العمولة (اختياري)
        fee_expense_account_id = None
        raw_fee_acc = data.get('fee_expense_account_id')
        if raw_fee_acc not in (None, '', 0, '0', False):
            try:
                fee_expense_account_id = int(raw_fee_acc)
                if not Account.query.get(fee_expense_account_id):
                    return jsonify({'error': 'حساب مصروف العمولة غير موجود'}), 404
            except (ValueError, TypeError):
                return jsonify({'error': 'معرف حساب مصروف العمولة غير صالح'}), 400

        # الحد الأدنى لمبلغ التسوية (اختياري)
        try:
            min_settlement_amount = float(data.get('min_settlement_amount') or 0.0)
        except (ValueError, TypeError):
            min_settlement_amount = 0.0
        if min_settlement_amount < 0:
            min_settlement_amount = 0.0

        # نمط التسوية
        # One settlement mode: a provider's deposit settles its payments together
        # (the owner, 6 Oct 2026: Tabby and Tamara deposit in batches). The
        # per-transaction mode is gone; asking for it is refused, not ignored.
        settlement_mode = str(data.get('settlement_mode') or 'bulk').strip().lower()
        if settlement_mode != 'bulk':
            return jsonify({'error': 'settlement_mode_not_supported',
                            'message': 'نمط التسوية المتاح هو التسوية المجمّعة وحدها'}), 400

        # عدد أيام تأخير الإيداع (للجدولة الأسبوعية)
        try:
            deposit_delay_days = int(data.get('deposit_delay_days') or 0)
        except (ValueError, TypeError):
            deposit_delay_days = 0
        if deposit_delay_days < 0:
            deposit_delay_days = 0
        if deposit_delay_days > 30:
            return jsonify({'error': 'أيام تأخير الإيداع يجب أن تكون بين 0 و 30'}), 400

        # نوع جدولة الإيداع ويومه (مستقل عن جدولة التسوية)
        try:
            deposit_schedule_type = _normalize_deposit_schedule_type(data.get('deposit_schedule_type'))
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400
        try:
            deposit_weekday = _normalize_weekday(data.get('deposit_weekday'))
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400
        if auto_settlement_enabled and deposit_schedule_type == 'weekday' and deposit_weekday is None:
            return jsonify({'error': 'يجب تحديد deposit_weekday عند اختيار جدولة إيداع أسبوعية'}), 400
        try:
            payment_method = PaymentMethod(
                payment_type=data['payment_type'],
                name=data['name'],
                commission_rate=data.get('commission_rate', 0.0),
                commission_fixed_amount=commission_fixed_amount,
                commission_timing=commission_timing,
                settlement_days=data.get('settlement_days', 0),
                auto_settlement_enabled=auto_settlement_enabled,
                settlement_schedule_type=settlement_schedule_type,
                settlement_weekday=settlement_weekday,
                settlement_bank_safe_box_id=settlement_bank_safe_box_id,
                fee_expense_account_id=fee_expense_account_id,
                min_settlement_amount=min_settlement_amount,
                settlement_mode=settlement_mode,
                deposit_delay_days=deposit_delay_days,
                deposit_schedule_type=deposit_schedule_type,
                deposit_weekday=deposit_weekday,
                is_active=data.get('is_active', True),
                applicable_invoice_types=applicable_invoice_types,
                default_safe_box_id=default_safe_box_id  # اختياري
            )
        except TypeError as exc:
            db.session.rollback()
            message = str(exc)
            outdated_keywords = {'applicable_invoice_types', 'parent_account_id', 'commission_fixed_amount'}
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
@require_permission('business.setup')
def update_payment_method(id):
    """تعديل وسيلة دفع"""
    try:
        payment_method = PaymentMethod.query.get(id)
        
        if not payment_method:
            return jsonify({'error': 'وسيلة الدفع غير موجودة'}), 404
        
        data = request.get_json()
        
        # Normalize proposed values (for cross-field validation)
        proposed_payment_type = data.get('payment_type', payment_method.payment_type)
        proposed_default_safe_box_id = data.get(
            'default_safe_box_id',
            getattr(payment_method, 'default_safe_box_id', None),
        )

        # Proposed auto settlement config
        proposed_auto_settlement_enabled = (
            bool(data.get('auto_settlement_enabled'))
            if 'auto_settlement_enabled' in data
            else bool(getattr(payment_method, 'auto_settlement_enabled', False))
        )
        try:
            proposed_schedule_type = (
                _normalize_settlement_schedule_type(data.get('settlement_schedule_type'))
                if 'settlement_schedule_type' in data
                else (_normalize_settlement_schedule_type(getattr(payment_method, 'settlement_schedule_type', 'days')))
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        try:
            proposed_weekday = (
                _normalize_weekday(data.get('settlement_weekday'))
                if 'settlement_weekday' in data
                else getattr(payment_method, 'settlement_weekday', None)
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        try:
            proposed_deposit_schedule_type = (
                _normalize_deposit_schedule_type(data.get('deposit_schedule_type'))
                if 'deposit_schedule_type' in data
                else (_normalize_deposit_schedule_type(getattr(payment_method, 'deposit_schedule_type', 'days')))
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        try:
            proposed_deposit_weekday = (
                _normalize_weekday(data.get('deposit_weekday'))
                if 'deposit_weekday' in data
                else getattr(payment_method, 'deposit_weekday', None)
            )
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

        proposed_bank_safe_box_id = (
            data.get('settlement_bank_safe_box_id', getattr(payment_method, 'settlement_bank_safe_box_id', None))
        )
        if 'settlement_bank_safe_box_id' in data and data.get('settlement_bank_safe_box_id') in (None, '', 0, '0', False):
            proposed_bank_safe_box_id = None

        # Allow explicit null to clear the default safe box
        if 'default_safe_box_id' in data and data.get('default_safe_box_id') in (None, '', 0, '0', False):
            proposed_default_safe_box_id = None

        # Validate proposed safe box if provided
        proposed_parent_account_id = None
        if proposed_default_safe_box_id not in (None, '', 0, '0', False):
            try:
                proposed_default_safe_box_id = int(proposed_default_safe_box_id)
            except Exception:
                return jsonify({'error': 'معرف الخزينة غير صالح'}), 400

            sb = SafeBox.query.get(proposed_default_safe_box_id)
            if not sb:
                return jsonify({'error': 'الخزينة غير موجودة'}), 404

            try:
                if (sb.safe_type or '').strip().lower() == 'gold':
                    return jsonify({'error': 'لا يمكن ربط وسيلة دفع بخزينة ذهب'}), 400
            except Exception:
                pass

            try:
                acc = getattr(sb, 'account', None)
                if not acc and getattr(sb, 'account_id', None):
                    acc = Account.query.get(int(sb.account_id))
                proposed_parent_account_id = getattr(acc, 'parent_id', None) if acc else None
            except Exception:
                proposed_parent_account_id = None
        else:
            try:
                if payment_method.default_safe_box and payment_method.default_safe_box.account:
                    proposed_parent_account_id = payment_method.default_safe_box.account.parent_id
            except Exception:
                proposed_parent_account_id = None

        # Validate proposed bank safe box (for auto settlement)
        if proposed_bank_safe_box_id not in (None, '', 0, '0', False):
            try:
                proposed_bank_safe_box_id = int(proposed_bank_safe_box_id)
            except Exception:
                return jsonify({'error': 'معرف الخزينة البنكية غير صالح'}), 400
            bank_sb = SafeBox.query.get(proposed_bank_safe_box_id)
            if not bank_sb:
                return jsonify({'error': 'الخزينة البنكية غير موجودة'}), 404
            try:
                if (bank_sb.safe_type or '').strip().lower() != 'bank':
                    return jsonify({'error': 'يجب اختيار خزينة من نوع بنك للتسوية التلقائية'}), 400
            except Exception:
                return jsonify({'error': 'يجب اختيار خزينة من نوع بنك للتسوية التلقائية'}), 400

        # If enabling auto settlement, enforce required fields.
        if proposed_auto_settlement_enabled:
            if proposed_default_safe_box_id in (None, '', 0, '0', False):
                return jsonify({'error': 'يجب تحديد خزينة مستحقات (clearing) لتمكين التسوية التلقائية'}), 400
            try:
                sb = SafeBox.query.get(int(proposed_default_safe_box_id))
                if not sb or (sb.safe_type or '').strip().lower() != 'clearing':
                    return jsonify({'error': 'يجب أن تكون الخزينة الافتراضية من نوع مستحقات تحصيل (clearing)'}), 400
            except Exception:
                return jsonify({'error': 'يجب أن تكون الخزينة الافتراضية من نوع مستحقات تحصيل (clearing)'}), 400
            if proposed_bank_safe_box_id in (None, '', 0, '0', False):
                return jsonify({'error': 'يجب تحديد خزينة بنكية لتمكين التسوية التلقائية'}), 400
            if proposed_schedule_type == 'weekday' and proposed_weekday is None:
                return jsonify({'error': 'يجب تحديد يوم الأسبوع عند اختيار جدول (weekday)'}), 400
            if proposed_deposit_schedule_type == 'weekday' and proposed_deposit_weekday is None:
                return jsonify({'error': 'يجب تحديد يوم الإيداع عند اختيار جدولة إيداع أسبوعية'}), 400

        # Prevent duplicates: same payment_type under same parent account (when parent is known)
        if proposed_parent_account_id:
            duplicate_for_update = (
                PaymentMethod.query
                .join(SafeBox, PaymentMethod.default_safe_box_id == SafeBox.id)
                .join(Account, SafeBox.account_id == Account.id)
                .filter(
                    PaymentMethod.payment_type == proposed_payment_type,
                    Account.parent_id == proposed_parent_account_id,
                    PaymentMethod.id != payment_method.id
                )
                .first()
            )

            if duplicate_for_update:
                return jsonify({'error': 'هذا النوع من وسائل الدفع مرتبط بالفعل بنفس الحساب الأب'}), 400

        # Apply updates
        if 'payment_type' in data:
            payment_method.payment_type = proposed_payment_type
        if 'name' in data:
            payment_method.name = data['name']
        if 'commission_rate' in data:
            payment_method.commission_rate = data['commission_rate']
        if 'commission_fixed_amount' in data:
            if data.get('commission_fixed_amount') in (None, '', False):
                payment_method.commission_fixed_amount = 0.0
            else:
                try:
                    fixed_val = float(data.get('commission_fixed_amount') or 0.0)
                except Exception:
                    return jsonify({'error': 'قيمة العمولة الثابتة غير صالحة'}), 400
                if fixed_val < 0:
                    return jsonify({'error': 'لا يمكن أن تكون العمولة الثابتة سالبة'}), 400
                payment_method.commission_fixed_amount = fixed_val
        if 'commission_timing' in data:
            try:
                payment_method.commission_timing = _normalize_commission_timing(
                    data.get('commission_timing')
                )
            except ValueError as exc:
                return jsonify({'error': str(exc)}), 400
        if 'settlement_days' in data:
            try:
                payment_method.settlement_days = int(data.get('settlement_days') or 0)
            except Exception:
                payment_method.settlement_days = 0
        if 'is_active' in data:
            payment_method.is_active = data['is_active']
        if 'default_safe_box_id' in data:
            payment_method.default_safe_box_id = proposed_default_safe_box_id
        if 'auto_settlement_enabled' in data:
            payment_method.auto_settlement_enabled = proposed_auto_settlement_enabled
        if 'settlement_schedule_type' in data:
            payment_method.settlement_schedule_type = proposed_schedule_type
        if 'settlement_weekday' in data:
            payment_method.settlement_weekday = proposed_weekday
        if 'settlement_bank_safe_box_id' in data:
            payment_method.settlement_bank_safe_box_id = proposed_bank_safe_box_id
        if 'applicable_invoice_types' in data:
            try:
                payment_method.applicable_invoice_types = _normalize_applicable_invoice_types(
                    data.get('applicable_invoice_types')
                )
            except ValueError as exc:
                return jsonify({'error': str(exc)}), 400
        if 'fee_expense_account_id' in data:
            raw_fee = data.get('fee_expense_account_id')
            if raw_fee in (None, '', 0, '0', False):
                payment_method.fee_expense_account_id = None
            else:
                try:
                    fee_id = int(raw_fee)
                except (ValueError, TypeError):
                    return jsonify({'error': 'معرف حساب مصروف العمولة غير صالح'}), 400
                if not Account.query.get(fee_id):
                    return jsonify({'error': 'حساب مصروف العمولة غير موجود'}), 404
                payment_method.fee_expense_account_id = fee_id
        if 'min_settlement_amount' in data:
            try:
                msa = float(data.get('min_settlement_amount') or 0.0)
                payment_method.min_settlement_amount = max(0.0, msa)
            except (ValueError, TypeError):
                pass
        if 'settlement_mode' in data:
            mode = str(data.get('settlement_mode') or 'bulk').strip().lower()
            if mode != 'bulk':
                return jsonify({'error': 'settlement_mode_not_supported',
                                'message': 'نمط التسوية المتاح هو التسوية المجمّعة وحدها'}), 400
            payment_method.settlement_mode = mode
        if 'deposit_delay_days' in data:
            try:
                ddv = int(data.get('deposit_delay_days') or 0)
            except (ValueError, TypeError):
                ddv = 0
            if ddv < 0:
                ddv = 0
            if ddv > 30:
                return jsonify({'error': 'أيام تأخير الإيداع يجب أن تكون بين 0 و 30'}), 400
            payment_method.deposit_delay_days = ddv
        if 'deposit_schedule_type' in data:
            try:
                dst = _normalize_deposit_schedule_type(data.get('deposit_schedule_type'))
                payment_method.deposit_schedule_type = dst
            except ValueError as exc:
                return jsonify({'error': str(exc)}), 400
        if 'deposit_weekday' in data:
            try:
                dwv = _normalize_weekday(data.get('deposit_weekday'))
                payment_method.deposit_weekday = dwv
            except ValueError as exc:
                return jsonify({'error': str(exc)}), 400
        # Validate weekday consistency after both fields are applied
        _dst_final = str(getattr(payment_method, 'deposit_schedule_type', 'days') or 'days')
        _dwv_final = getattr(payment_method, 'deposit_weekday', None)
        _auto_final = bool(getattr(payment_method, 'auto_settlement_enabled', False))
        if _auto_final and _dst_final == 'weekday' and _dwv_final is None:
            return jsonify({'error': 'يجب تحديد deposit_weekday عند اختيار جدولة إيداع أسبوعية'}), 400

        db.session.commit()
        
        return jsonify({
            'message': 'تم تحديث وسيلة الدفع بنجاح',
            'payment_method': payment_method.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods/<int:id>', methods=['DELETE'])
@require_permission('business.setup')
def delete_payment_method(id):
    """حذف وسيلة دفع"""
    try:
        payment_method = PaymentMethod.query.get(id)
        
        if not payment_method:
            return jsonify({'error': 'وسيلة الدفع غير موجودة'}), 404
        
        # نسمح بالحذف الفعلي إذا لم تُستخدم في أي دفعة فاتورة
        used_payments = 0
        used_invoices = 0
        try:
            used_payments = InvoicePayment.query.filter_by(
                payment_method_id=payment_method.id
            ).count()
        except Exception:
            used_payments = 0

        try:
            used_invoices = Invoice.query.filter_by(
                payment_method_id=payment_method.id
            ).count()
        except Exception:
            used_invoices = 0

        if used_payments == 0 and used_invoices == 0:
            db.session.delete(payment_method)
            db.session.commit()
            return jsonify({
                'message': 'تم حذف وسيلة الدفع بنجاح (غير مرتبطة بعمليات)',
                'deleted': True,
                'deactivated': False,
                'used_in_invoices': used_invoices,
                'used_in_payments': used_payments,
            }), 200

        # إن كانت مستخدمة في دفعات/فواتير، نعطلها لتفادي قيود FK ولحفظ التاريخ
        payment_method.is_active = False
        db.session.commit()

        return jsonify({
            'message': 'تم تعطيل وسيلة الدفع لأنها مستخدمة في عمليات سابقة',
            'deleted': False,
            'deactivated': True,
            'used_in_invoices': used_invoices,
            'used_in_payments': used_payments,
            'payment_method': payment_method.to_dict(),
        }), 200
        
    except IntegrityError:
        # Fallback: if any FK constraint triggers, rollback and deactivate.
        db.session.rollback()
        try:
            payment_method = PaymentMethod.query.get(id)
            if payment_method:
                payment_method.is_active = False
                db.session.commit()
                return jsonify({
                    'message': 'تعذر الحذف بسبب ارتباطات سابقة؛ تم تعطيل وسيلة الدفع بدلاً من ذلك',
                    'deleted': False,
                    'deactivated': True,
                    'payment_method': payment_method.to_dict(),
                }), 200
        except Exception:
            db.session.rollback()
        return jsonify({'error': 'delete_failed_due_to_references'}), 409
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@payment_methods_api.route('/payment-methods/update-order', methods=['PUT'])
@require_permission('business.setup')
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
@require_permission('business.setup')
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

        if not payment_types:
            ensure_default_payment_types()
            payment_types = PaymentType.query.filter_by(is_active=True).order_by(PaymentType.sort_order).all()
        return jsonify([pt.to_dict() for pt in payment_types]), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@payment_methods_api.route('/payment-types', methods=['POST'])
@require_permission('business.setup')
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
@require_permission('business.setup')
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
