# ⚠️  FROZEN — لا تُضف routes جديدة هنا. هذا الملف أصبح مكتبة shared helpers فقط.
# كل route جديدة تذهب إلى ملف domain مستقل داخل routes/:
#   pricing      → routes/pricing.py     ✅ (gold price, gold costing)
#   customers    → routes/customers.py   ✅ (7 routes)
#   suppliers    → routes/suppliers.py   ✅ (10 routes)
#   accounts     → routes/accounts.py    ✅ (22 routes)
#   invoices     → routes/invoices.py    ✅ (19 routes)
#   employees    → routes/employees.py   ✅ (36 routes)
#   reports      → routes/reports.py     ✅ (32 routes)
#   catalog      → routes/catalog.py     ✅ (16 routes — items, categories, category-weight)
#   safe_boxes   → routes/safe_boxes.py  ✅ (18 routes)
#   journals     → routes/journals.py    ✅ (8 routes)
#   vouchers     → routes/vouchers.py    ✅ (8 routes)
#   clearing     → routes/clearing.py    ✅ (6 routes + weight-closing cash/execute)
#   office_res   → routes/office_reservations.py ✅ (5 routes)
#   admin        → routes/admin.py       ✅ (9 routes — temp-pdf + admin)
#   system       → routes/system.py      ✅ (21 routes — debug, settings, reset, backup, melting-renewal)
# routes/__init__.py = مكتبة shared helpers فقط (0 routes)
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import hashlib
import hmac
import base64
import html
import socket
from functools import wraps
from urllib.parse import quote
from flask import Blueprint, request, jsonify, g, current_app, send_file
import io
import os
import json
import tempfile
import zipfile
import sqlite3
from datetime import datetime, timedelta
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker, joinedload
from sqlalchemy import func, or_, and_, not_, case, cast, String, Integer
from gold_price import fetch_gold_price, save_gold_price
from models import (
    GoldPrice,
    db,
    Customer,
    Item,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    Account,
    JournalEntry,
    JournalEntryLine,
    Settings,
    Supplier,
    VoucherAccountLine,
    Voucher,
    PaymentMethod,
    InvoicePayment,
    SafeBoxTransaction,
    AccountingMapping,
    InventoryCostingConfig,
    WeightClosingOrder,
    WeightClosingExecution,
    Employee,
    Payroll,
    Attendance,
    BonusRule,
    EmployeeBonus,
    BonusInvoiceLink,
    SafeBox,
    Office,
    OfficeReservation,
    User,
    Category,
    AuditLog,
    SupplierGoldTransaction,
    SettlementLine,
    GoalAchievement,
)
from utils import normalize_number
try:
    from backend.config import REQUIRE_AUTH_FOR_INVOICE_CREATE
except ImportError:  # Local scripts running from backend/ directory
    from config import REQUIRE_AUTH_FOR_INVOICE_CREATE
from office_supplier_service import ensure_office_supplier
from office_account_service import ensure_office_account
from party_account_service import ensure_customer_accounts, ensure_supplier_accounts
from account_pair_service import link_accounts, unlink_account
from settlement_state_service import get_settled_amounts, is_locked
from allocation_service import AllocationService
from code_generator import generate_item_code, generate_barcode_from_item_code, validate_item_code
from dual_system_helpers import (
    create_dual_journal_entry,
    verify_dual_balance,
    get_account_balances,
)
from services.live_balances import (
    live_balances_by_account_ids,
    safe_box_balance,
    safe_box_balances_bulk,
)
from gold_costing_service import GoldCostingService, ScrapCostingService
from category_weight_tracking import (
    get_category_weight_balances,
    record_category_weight_movements_for_invoice_payload,
)
from datetime import datetime, date, time, timedelta
from collections import defaultdict
from statistics import pstdev
from auth_decorators import get_current_user, require_auth, require_permission, require_any_permission, require_admin


# Core Infrastructure → core/
from core.responses import _wrap_api_exceptions  # noqa: F401
from core.database import _DB_COLUMN_CACHE  # noqa: F401


def _normalize_account_ref(value):
    """Accept either an account id or account_number-like integer."""
    if value in (None, '', False, 0, '0'):
        return None
    try:
        return int(str(value).strip())
    except Exception:
        return None


def _normalize_fk_ref(value):
    """Accept nullable integer FK values (treat 0 as null)."""
    if value in (None, '', False, 0, '0'):
        return None
    try:
        return int(str(value).strip())
    except Exception:
        return None


from core.database import _db_has_column  # noqa: F401
from permissions import ALL_PERMISSIONS

api = Blueprint('api', __name__)

# Public (unauthenticated) endpoints.
# This blueprint intentionally has no auth `before_request` so it can be used
# on the login screen.
public_api = Blueprint('public_api', __name__)


# System domain → routes/system.py
# (_is_production_env, debug_db_info, _is_sqlite_database, _is_postgres_database,
#  _sqlite_db_path, _settings_diag_headers, backup helper functions,
#  _pg_tools_available, _postgres_conn_parts, _create_postgres_backup_to_file,
#  _restore_postgres_from_backup_file, _restore_sqlite_from_backup_file,
#  _server_backup_dir, _actor_username, _append_restore_audit,
#  _create_pre_restore_snapshot_zip)


_PERMISSION_RESOURCE_MAP = {
    # system
    'settings': 'system.settings',
    'system': 'system',

    # users (AppUser CRUD is in auth_routes, not here)

    # business entities
    'customers': 'customers',
    'suppliers': 'suppliers',
    'items': 'items',
    'invoices': 'invoices',
    'employees': 'employees',
    'accounts': 'accounts',
    'safe-boxes': 'safe_boxes',
    'safe_boxes': 'safe_boxes',
    'gold_price': 'gold_price',
    'gold-price': 'gold_price',

    # accounting
    'journal_entries': 'journal',
    'journal-entries': 'journal',
    'vouchers': 'vouchers',
}


def _infer_permission_code(path: str, method: str) -> str | None:
    """Infer a permission code from request path+method.

    This is intentionally conservative: it only returns a permission that exists
    in `ALL_PERMISSIONS` (permissions catalog). If no match is found, returns None.
    """
    # Normalize segments and drop leading /api
    segments = [s for s in (path or '').strip('/').split('/') if s]
    if segments and segments[0] == 'api':
        segments = segments[1:]
    if not segments:
        return None

    resource = segments[0]
    remainder = segments[1:]

    # Special-case system settings: allow read for all authenticated users,
    # but keep updates restricted to system.settings.
    mapped = _PERMISSION_RESOURCE_MAP.get(resource)
    if mapped == 'system.settings':
        if (method or '').upper() == 'GET':
            return None
        return 'system.settings' if 'system.settings' in ALL_PERMISSIONS else None

    # Determine action
    action = None
    m = (method or '').upper()

    # action endpoints
    last = remainder[-1] if remainder else ''
    if resource in ('journal_entries', 'journal-entries'):
        if m == 'GET':
            action = 'view'
        elif m == 'POST':
            if last in ('soft_delete', 'delete'):
                action = 'delete'
            elif last == 'restore':
                action = 'edit'
            else:
                action = 'create'
        elif m in ('PUT', 'PATCH'):
            action = 'edit'
        elif m == 'DELETE':
            action = 'delete'

        code = f'journal.{action}'
        return code if code in ALL_PERMISSIONS else None

    if resource == 'gold_price' or resource == 'gold-price':
        if m == 'GET':
            action = 'view'
        else:
            action = 'update'
        code = f'gold_price.{action}'
        return code if code in ALL_PERMISSIONS else None

    module = mapped or resource
    # If mapped is 'system', attempt system.* actions
    if module == 'system':
        # Most system endpoints in this blueprint should require settings.
        code = 'system.settings'
        return code if code in ALL_PERMISSIONS else None

    # Default CRUD mapping
    if m == 'GET':
        action = 'view'
    elif m == 'POST':
        # If POST is clearly an action endpoint, map to edit/delete where possible.
        if last in ('soft_delete', 'delete'):
            action = 'delete'
        elif last in ('restore', 'adjust', 'toggle-active', 'toggle_active'):
            action = 'edit'
        else:
            action = 'create'
    elif m in ('PUT', 'PATCH'):
        action = 'edit'
    elif m == 'DELETE':
        action = 'delete'

    if action is None:
        return None

    # Try direct module.action first
    candidate = f'{module}.{action}'
    if candidate in ALL_PERMISSIONS:
        return candidate

    # Some resources may be plural/singular mismatch; try a simple singular form
    if module.endswith('s'):
        singular = module[:-1]
        candidate2 = f'{singular}.{action}'
        if candidate2 in ALL_PERMISSIONS:
            return candidate2

    return None


@api.before_request
def _enforce_api_auth_and_permissions():
    """Global enforcement for the main API blueprint.

    Historically many endpoints in routes.py were not decorated with require_auth/require_permission.
    This hook ensures that:
    - all /api/* endpoints under this blueprint require authentication
    - if a matching permission exists in the permissions catalog, it is enforced
    """
    # Always allow preflight
    if request.method == 'OPTIONS':
        return None

    # If another before_request already set current_user (eg. explicit decorators), keep it.
    user = getattr(g, 'current_user', None)
    if not user:
        user = get_current_user()
        if not user:
            auth_error = getattr(g, 'auth_error', None)
            if auth_error == 'session_expired':
                return jsonify({
                    'success': False,
                    'message': 'انتهت الجلسة بسبب عدم النشاط. الرجاء تسجيل الدخول مرة أخرى',
                    'error': 'session_expired'
                }), 401
            return jsonify({
                'success': False,
                'message': 'يجب تسجيل الدخول أولاً',
                'error': 'authentication_required'
            }), 401
        g.current_user = user

    # Block inactive accounts when applicable
    if hasattr(user, 'is_active') and not bool(getattr(user, 'is_active', True)):
        return jsonify({
            'success': False,
            'message': 'الحساب غير نشط',
            'error': 'user_inactive'
        }), 403

    # ✅ Public-for-all-authenticated: viewing gold/ounce price should not be permission-gated.
    # Keep authentication and inactive-user blocking, but skip permission enforcement.
    try:
        normalized_path = (request.path or '').rstrip('/')
        if request.method == 'GET' and normalized_path in ('/api/gold_price', '/api/gold-price'):
            return None
    except Exception:
        pass

    # Legacy admin has full access
    if bool(getattr(user, 'is_admin', False)):
        return None

    perm_code = _infer_permission_code(request.path, request.method)
    if perm_code and perm_code in ALL_PERMISSIONS:
        try:
            if not user.has_permission(perm_code):
                return jsonify({
                    'success': False,
                    'message': 'ليس لديك صلاحية لتنفيذ هذا الإجراء',
                    'error': 'permission_denied',
                    'required_permission': perm_code,
                }), 403
        except Exception:
            return jsonify({
                'success': False,
                'message': 'تعذر التحقق من الصلاحيات',
                'error': 'permission_check_failed',
                'required_permission': perm_code,
            }), 403

    return None


from core.dates import _parse_iso_date  # noqa: F401


class InlineItemCreationError(Exception):
    """Validation/creation errors for inline purchase items."""


def _inline_item_float(value, default=0.0):
    if value in (None, '', False):
        return default
    try:
        return float(normalize_number(str(value)))
    except Exception:
        try:
            return float(value)
        except (TypeError, ValueError):
            return default


def _inline_pick_number(item_data, keys, default=0.0):
    for key in keys:
        if key is None:
            continue
        if key in item_data and item_data[key] not in (None, ''):
            return _inline_item_float(item_data[key], default)
    return default

# DEFAULT_WEIGHT_CLOSING_SETTINGS → accounting/weight_closing.py (re-exported above)
# System domain → routes/system.py
# (GET /weight-closing/settings, PUT /weight-closing/settings)



# System domain → routes/system.py
# (GET /system-alerts, PUT /system-alerts/<id>/review)



from core.number_helpers import _coerce_float  # noqa: F401


def validate_bridge_account_balance(bridge_account_id, tolerance=0.01):
    """
    🆕 التحقق من أن رصيد حساب الجسر = صفر بعد كل فاتورة شراء (مورد).
    
    القاعدة الذهبية:
    - حساب الجسر يجب أن يُصفّر دائماً بعد كل معاملة
    - إذا بقي رصيد = خلل محاسبي يجب التحقيق فيه
    
    Args:
        bridge_account_id: معرف حساب الجسر
        tolerance: هامش خطأ مسموح (للفواصل العشرية)
    
    Returns:
        dict: {'is_balanced': bool, 'bridge_balance': float, 'warning': str}
    """
    if not bridge_account_id:
        return {'is_balanced': True, 'bridge_balance': 0.0, 'warning': None}
    
    bridge_account = Account.query.get(bridge_account_id)
    if not bridge_account:
        return {'is_balanced': False, 'bridge_balance': 0.0, 'warning': 'حساب الجسر غير موجود'}
    
    # الحصول على الرصيد النقدي
    # The ledger's balance (BALANCE-001 B3), not the cached column.
    from services.live_balances import live_balances_by_account_ids
    bridge_balance = float((live_balances_by_account_ids([bridge_account.id]).get(int(bridge_account.id)) or {}).get('cash') or 0.0)
    
    # التحقق من أن الرصيد قريب من الصفر
    is_balanced = abs(bridge_balance) <= tolerance
    
    result = {
        'is_balanced': is_balanced,
        'bridge_balance': round(bridge_balance, 2),
        'bridge_account_number': bridge_account.account_number,
        'bridge_account_name': bridge_account.name,
        'warning': None
    }
    
    if not is_balanced:
        result['warning'] = (
            f"⚠️ تحذير: رصيد حساب الجسر ({bridge_account.account_number} - {bridge_account.name}) "
            f"غير متوازن: {bridge_balance:.2f} ريال. "
            f"يجب أن يكون الرصيد = صفر بعد كل معاملة. "
            f"يرجى التحقيق في القيود المحاسبية."
        )
        print(result['warning'])
    else:
        print(f"✅ رصيد حساب الجسر متوازن: {bridge_balance:.2f} ريال (ضمن هامش الخطأ المسموح)")
    
    return result


def get_current_gold_price():
    from pricing.gold_price_service import get_current_gold_price as _impl
    return _impl()


# The startup chart bootstrap (ensure_weight_closing_support_accounts, with
# _repair_inventory_wage_memo_links and dual_system_helpers.link_memo_accounts_helper)
# is gone (CHART-002 step 4c2): it built, renamed, re-parented and relinked
# accounts from config's numbers -- 1310's twin as 71310000, 7340 renumbered
# 71340. The chart is data; its pairs are links (account_pair_service).


# _load_weight_closing_settings → accounting/weight_closing.py (re-exported above)
def _generate_reservation_code(prefix='RES'):
    timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
    total = OfficeReservation.query.count() + 1
    return f"{prefix}-{timestamp}-{total:04d}"


def _generate_journal_entry_number(prefix='JE', entry_date=None):
    from accounting.reference_number_service import generate_journal_entry_number
    return generate_journal_entry_number(prefix, entry_date)


def _next_invoice_type_id(invoice_types):
    """Allocate the next sequential `Invoice.invoice_type_id` for given invoice_type(s).

    Notes:
    - We intentionally keep existing semantics: sequence is per invoice_type (or group of
      invoice types), not per-year.
    - Uses MAX() + a session cache so multiple invoices created in the same request/flush
      don't collide.
    """
    try:
        types = [str(t) for t in (invoice_types or []) if str(t).strip()]
    except Exception:
        types = []

    if not types:
        # Fallback: global sequence
        types = []

    cache = None
    try:
        cache = db.session.info.setdefault('_invoice_type_id_cache', {})
    except Exception:
        cache = {}

    cache_key = tuple(sorted(types))
    last_seq = cache.get(cache_key)
    if last_seq is None:
        q = db.session.query(func.max(Invoice.invoice_type_id))
        if types:
            q = q.filter(Invoice.invoice_type.in_(types))
        last_seq = int(q.scalar() or 0)

    next_seq = int(last_seq) + 1
    while True:
        exists_q = Invoice.query.filter(Invoice.invoice_type_id == next_seq)
        if types:
            exists_q = exists_q.filter(Invoice.invoice_type.in_(types))
        if not exists_q.first():
            cache[cache_key] = next_seq
            return next_seq
        next_seq += 1


def _record_memo_weight_transfer(journal_entry_id, *, debit_account_id=None, credit_account_id=None, weight_main_karat=0.0):
    if weight_main_karat <= 0 or not debit_account_id or not credit_account_id:
        return

    karat_value = get_main_karat() or 21
    if karat_value not in (18, 21, 22, 24):
        karat_value = 21

    weight_at_karat = convert_from_main_karat(weight_main_karat, karat_value)
    if weight_at_karat <= 0:
        return

    debit_field = f'debit_{karat_value}k'
    credit_field = f'credit_{karat_value}k'

    description = f'تحويل وزني {weight_main_karat:.3f} عيار {karat_value}'

    create_dual_journal_entry(
        journal_entry_id=journal_entry_id,
        account_id=debit_account_id,
        description=description,
        **{debit_field: weight_at_karat}
    )

    create_dual_journal_entry(
        journal_entry_id=journal_entry_id,
        account_id=credit_account_id,
        description=description,
        **{credit_field: weight_at_karat}
    )


def _gold_inventory_account_id(kind: str = 'new') -> int:
    """The gold's financial inventory -- one account for every karat, new apart
    from scrap: the mapped role gold_inventory_new / gold_inventory_scrap
    (CHART-002 step 4), or AccountNotMapped.

    It was two finders. The invoices' read the weight-closing settings' account
    numbers (1300 new / 1310 scrap -- the settings empty on production, the
    numbers the code's own defaults). The weight closing's read one setting,
    'inventory_account_id', default 1310, as a row id first -- so new gold's
    cost left the scrap inventory, and the day account row 1310 is made (1305
    on the production copy, 12 Oct 2026) it would have left that account. Its
    path never posted on production (every execution an office reservation).
    """
    return require_account(DEFAULT_MAPPING_OPERATION_TYPE,
                           'gold_inventory_scrap' if kind == 'scrap' else 'gold_inventory_new')


def _resolve_account_from_id_or_number(value):
    """Resolve an account by either internal id or account_number.

    Some deployments store values like `1100` in settings intending an
    `account_number`, while the code path expects a database primary key.
    """
    if value in (None, '', 0, False):
        return None
    try:
        value_int = int(value)
    except Exception:
        value_int = None

    if value_int is not None:
        acc = Account.query.get(value_int)
        if acc:
            return acc
        return Account.query.filter_by(account_number=str(value_int)).first()

    return Account.query.filter_by(account_number=str(value)).first()


def _resolve_inventory_account_id_for_invoice(invoice_type: str, gold_type: str) -> int:
    """The financial inventory for an invoice: scrap for scrap gold and for a
    purchase from a customer, new otherwise -- one account for every karat."""
    kind = 'scrap' if (str(gold_type or '').strip().lower() == 'scrap'
                       or (invoice_type or '').strip() == 'شراء من عميل') else 'new'
    return _gold_inventory_account_id(kind)


def _invoice_weight_mk_v2(invoice: Invoice) -> float:
    """حساب وزن الفاتورة بالعيار الرئيسي (v2) — الوزن الكلي للسطر بدون ضرب في الكمية.
    الأولوية: karat_lines → InvoiceItem.weight (snapshot) → total_weight (احتياط).
    """
    if not invoice:
        return 0.0
    main_karat = get_main_karat() or 21
    w = 0.0
    karat_lines = getattr(invoice, 'karat_lines', None) or []
    if karat_lines:
        for line in karat_lines:
            lw = float(getattr(line, 'weight_grams', 0) or 0)
            lk = float(getattr(line, 'karat', main_karat) or main_karat)
            if lw > 0:
                w += lw * lk / main_karat
        if w > 0:
            return w
    items = getattr(invoice, 'items', None) or []
    if items:
        for ii in items:
            iw = float(getattr(ii, 'weight', 0) or 0)
            ik = float(getattr(ii, 'karat', 0) or 0) or main_karat  # fallback للعيار الرئيسي
            if iw > 0:
                w += iw * ik / main_karat
        if w > 0:
            return w
    # فاتورة بدون بنود — total_weight هو وزن خام بالعيار الرئيسي (يُخزَّن مباشرة)
    return float(getattr(invoice, 'total_weight', 0) or 0)


def _invoice_weight_in_main_karat(invoice: Invoice) -> float:
    """Wrapper لـ _invoice_weight_mk_v2 — الأسماء القديمة محفوظة للتوافق."""
    return _invoice_weight_mk_v2(invoice)


def create_item_from_invoice_payload(item_data):
    if not isinstance(item_data, dict):
        raise InlineItemCreationError('بيانات الصنف غير صالحة')

    name = (item_data.get('name') or 'صنف بدون اسم').strip() or 'صنف بدون اسم'

    item_code = (item_data.get('item_code') or '').strip()
    if item_code:
        validation = validate_item_code(item_code)
        if not validation['is_valid']:
            raise InlineItemCreationError(validation['message'])
        if Item.query.filter_by(item_code=item_code).first():
            raise InlineItemCreationError(f'كود الصنف {item_code} مستخدم بالفعل')
    else:
        item_code = generate_item_code()

    barcode = (item_data.get('barcode') or '').strip()
    if not barcode:
        barcode = generate_barcode_from_item_code(item_code)

    weight_value = _inline_pick_number(item_data, ['weight', 'weight_grams', 'total_weight'])
    if weight_value <= 0:
        raise InlineItemCreationError('وزن الصنف يجب أن يكون أكبر من صفر')

    karat_value = item_data.get('karat', 21)
    try:
        karat_text = str(int(round(float(karat_value))))
    except Exception:
        karat_text = str(karat_value)

    wage_per_gram = _inline_pick_number(
        item_data,
        ['manufacturing_wage_per_gram', 'wage_per_gram'],
        default=0.0,
    )
    wage_total = _inline_pick_number(
        item_data,
        ['wage_total', 'wage', 'total_wage'],
        default=weight_value * wage_per_gram,
    )

    stones_weight = _inline_pick_number(item_data, ['stones_weight'], default=0.0)
    stones_value = _inline_pick_number(item_data, ['stones_value'], default=0.0)

    new_item = Item(
        item_code=item_code,
        name=name,
        barcode=barcode,
        karat=karat_text,
        weight=weight_value,
        wage=wage_total,
        manufacturing_wage_per_gram=wage_per_gram,
        description=item_data.get('description'),
        price=_inline_item_float(item_data.get('price'), 0.0),
        stock=int(item_data.get('stock') or 1),
        count=int(item_data.get('count') or 1),
        category_id=item_data.get('category_id'),
        has_stones=bool(item_data.get('has_stones', False)),
        stones_weight=stones_weight,
        stones_value=stones_value,
    )

    try:
        db.session.add(new_item)
        db.session.flush()
    except IntegrityError as exc:
        raise InlineItemCreationError('كود الصنف أو الباركود مستخدم مسبقاً') from exc

    return new_item


from core.dates import _parse_iso_time  # noqa: F401

def _generate_employee_code():
    prefix = f"EMP-{datetime.now().year}"
    latest_employee = (
        Employee.query.filter(Employee.employee_code.like(f"{prefix}%"))
        .order_by(Employee.employee_code.desc())
        .first()
    )

    if not latest_employee:
        return f"{prefix}-0001"

    try:
        last_sequence = int(str(latest_employee.employee_code).split('-')[-1])
    except (ValueError, AttributeError):
        last_sequence = latest_employee.id or 0

    return f"{prefix}-{last_sequence + 1:04d}"


# _get_settings_singleton → core/settings.py
# System domain → routes/system.py
# (GET /settings, PUT /settings)

# System domain → routes/system.py
# (POST /system/reset, _reset_transactions, _reset_balances_only,
#  _reset_oversight_only, _reset_customers_suppliers, _reset_full_system_wipe, etc.)


# System domain → routes/system.py
# (GET /system/reset/info)


# System domain → routes/system.py
# (GET /system/backup/download, GET /system/backup/drive/status,
#  POST /system/backup/drive/upload, GET /system/backup/drive/list,
#  GET /system/backup/drive/download/<file_id>, POST /system/backup/restore)


# Statement Verification functions → accounting/statement_verification.py (re-exported above)

# System domain → routes/system.py
# (POST /statements/qr-sign)


# Accounts domain → routes/accounts.py (statement routes)
# (GET /accounts/<id>/statement, GET /accounts/by-number/<num>/statement,
#  GET /accounts/<id>/statement_merged, GET /accounts/by-number/<num>/statement_merged)

# Customers domain → routes/customers.py
# (DELETE /customers/<id>, GET /customers/<id>/statement,
#  GET /customers/next-code, GET /customers/gold-balances,
#  GET /customers, POST /customers, PUT /customers/<id>)

# Suppliers domain → routes/suppliers.py
# (GET /suppliers/next-code, GET /suppliers,
#  POST /suppliers, PUT /suppliers/<id>, DELETE /suppliers/<id>,
#  GET /suppliers/<id>/ledger, GET /suppliers/<id>/statement,
#  GET /suppliers/<id>/weight-summary, POST /suppliers/<id>/send-gold)

# Items CRUD
# Catalog domain → routes/catalog.py
# (PUT /items/<id>, DELETE /items/<id>, GET /items,
#  GET /items/search/barcode/<barcode>, POST /items,
#  GET /purchase-items, POST /purchase-items,
#  DELETE /purchase-items/<id>,
#  GET /categories, GET /categories/<id>,
#  POST /categories, PUT /categories/<id>, DELETE /categories/<id>,
#  GET /category-weight/balances,
#  GET /category-weight/movements,
#  POST /category-weight/adjustments)

# Safe-boxes domain → routes/safe_boxes.py (cluster A)
# (GET /safe-boxes/<id>/transactions, GET /safe-boxes/<id>/balance,
#  GET /safe-boxes/balances, GET /safe-boxes/stones-balance,
#  GET /safe-boxes/reconciliation,
#  POST /safe-boxes/repair-transactions)

# Invoices domain → routes/invoices.py
# (PUT /invoices/<id>/print-template)

# DEFAULT_MAPPING_OPERATION_TYPE + get_account_id_for_mapping → accounting/mappings.py (re-exported above)

# _ACCOUNT_NUMBER_CACHE + get_account_id_by_number → accounting/mappings.py (re-exported above)


# Invoices domain → routes/invoices.py
# (_create_gold24k_settlement_entries; the karat-difference commission is
#  accounting/karat_diff_commission.py's, item 9)

# Invoices domain → routes/invoices.py
# (POST /invoices — add_invoice, ~5600 lines)

# Invoices domain → routes/invoices.py (devtools)
# (POST /devtools/import/sales-invoices)

# Accounts domain → routes/accounts.py (CRUD part 1)
# (GET /accounts, GET /accounts/<id>, GET /accounts/export,
#  POST /accounts/import, GET /accounts/balances, GET /accounts/hierarchy)

# Invoices domain → routes/invoices.py (return routes)
# (GET /invoices/<id>/returns, GET /invoices/<id>/can-return,
#  GET /invoices/returnable)


# Accounts domain → routes/accounts.py (CRUD part 2)
# (GET /accounts/next-number/<parent>, POST /accounts/validate-number,
#  GET /accounts/capacity/<category>, POST /accounts,
#  PUT /accounts/<id>, DELETE /accounts/<id>)


# Journal Entries CRUD
# Journal-entries domain → routes/journals.py (JE helpers)
# (_parse_journal_entries_query_datetime, _journal_entry_line_to_dict,
#  _journal_entry_totals, _serialize_journal_entry_list_item)

def _try_process_due_auto_clearing_settlements(*, payment_method_ids=None):
    """Best-effort trigger for due auto settlements after payment creation."""
    method_ids = set()
    for raw_value in payment_method_ids or []:
        try:
            method_ids.add(int(raw_value))
        except Exception:
            continue

    if not method_ids:
        return None

    try:
        has_enabled_method = (
            PaymentMethod.query
            .filter(
                PaymentMethod.id.in_(sorted(method_ids)),
                PaymentMethod.is_active == True,
                PaymentMethod.auto_settlement_enabled == True,
            )
            .first()
            is not None
        )
    except Exception:
        has_enabled_method = False

    if not has_enabled_method:
        return None

    try:
        from clearing_settlement_scheduler import get_clearing_settlement_scheduler

        scheduler = get_clearing_settlement_scheduler(current_app._get_current_object())
        return scheduler.process_due_settlements()
    except Exception:
        try:
            current_app.logger.exception('auto_clearing_settlement_trigger_failed')
        except Exception:
            pass
        return None


# Journal-entries domain → routes/journals.py
# (GET /journal_entries)

# Karat Engine → pricing/karat_service.py
from pricing.karat_service import get_main_karat, convert_to_main_karat, convert_from_main_karat  # noqa: F401

# Voucher Engine → accounting/voucher_engine.py
from accounting.voucher_engine import (  # noqa: F401
    _generate_journal_entry_number,
    generate_voucher_number,
    _update_account_balances_from_journal_lines,
    create_journal_entry_from_voucher,
    post_entry_of_approved_voucher,
    _append_safe_transactions_for_voucher,
)

# Statement Verification → accounting/statement_verification.py
from accounting.statement_verification import (  # noqa: F401
    _qr_hmac_secret,
    _qr_canonical_json,
    _sign_qr_payload,
    _public_base_url,
    _b64url_encode_utf8,
    _b64url_decode_utf8,
    _build_qr_verify_token,
    _build_statement_verify_url,
    _verify_statement_token,
    _build_statement_qr_signed_payload,
)

# Accounting Mappings → accounting/mappings.py
from accounting.mappings import (  # noqa: F401
    DEFAULT_MAPPING_OPERATION_TYPE,
    _ACCOUNT_NUMBER_CACHE,
    get_account_id_by_number,
    get_account_id_for_mapping,
    require_account,
)

# Weight Closing → accounting/weight_closing.py
from accounting.weight_closing import (  # noqa: F401
    DEFAULT_WEIGHT_CLOSING_SETTINGS,
    _load_weight_closing_settings,
)

# Settings Singleton → core/settings.py
from core.settings import _get_settings_singleton  # noqa: F401

# Account Balances → accounting/balances.py
from accounting.balances import _recalculate_account_balances_for_accounts  # noqa: F401

# Safe Box Transactions → accounting/safe_boxes.py
from accounting.safe_boxes import (  # noqa: F401
    _rebuild_safe_box_transactions_for_journal_entry,
    _ensure_safe_box_transactions_for_invoice_je,
)



def _ensure_weight_tracking_account(account_id):
    if not account_id:
        return None
    account = Account.query.get(account_id)
    if account and not account.tracks_weight:
        account.tracks_weight = True
        db.session.add(account)
        db.session.flush()
    return account


def _get_manufacturing_wage_inventory_account_id():
    legacy_supplier_purchase = 'شراء' + ' من ' + 'مورد'
    for operation in ('شراء', legacy_supplier_purchase, 'بيع'):
        acc_id = get_account_id_for_mapping(operation, 'manufacturing_wage_inventory')
        if acc_id:
            return acc_id
    return None


def _account_weight_balance_main_karat(account):
    if not account or not account.tracks_weight:
        return 0.0
    total = 0.0
    total += convert_to_main_karat(account.balance_18k or 0.0, 18)
    total += convert_to_main_karat(account.balance_21k or 0.0, 21)
    total += convert_to_main_karat(account.balance_22k or 0.0, 22)
    total += convert_to_main_karat(account.balance_24k or 0.0, 24)
    return total


# _recalculate_account_balances_for_accounts → accounting/balances.py
# System domain → routes/system.py
# (_rebuild_all_account_balances, POST /system/rebuild-account-balances)



# _update_account_balances_from_journal_lines → accounting/voucher_engine.py (re-exported above)


def _account_weight_balance_main_karat(account):
    if not account or not account.tracks_weight:
        return 0.0
    total = 0.0
    total += convert_to_main_karat(account.balance_18k or 0.0, 18)
    total += convert_to_main_karat(account.balance_21k or 0.0, 21)
    total += convert_to_main_karat(account.balance_22k or 0.0, 22)
    total += convert_to_main_karat(account.balance_24k or 0.0, 24)
    return round(total, 6)


def _line_weight_total_in_main_karat(line, side, main_karat_value=None):
    """Normalize a journal line's weight columns to the main karat (default 21k)."""
    if not line:
        return 0.0
    prefix = 'debit' if side == 'debit' else 'credit'
    if main_karat_value is None or main_karat_value <= 0:
        main_karat_value = get_main_karat() or 21

    total = 0.0
    karat_fields = {
        18: getattr(line, f'{prefix}_18k', 0) or 0,
        21: getattr(line, f'{prefix}_21k', 0) or 0,
        22: getattr(line, f'{prefix}_22k', 0) or 0,
        24: getattr(line, f'{prefix}_24k', 0) or 0,
    }

    for karat, value in karat_fields.items():
        if value:
            total += (float(value) * karat) / main_karat_value

    if total == 0:
        fallback = getattr(line, f'{prefix}_weight', 0) or 0
        total = float(fallback)

    return float(total)


def _net_line_weight_in_main_karat(line, main_karat_value=None):
    credit_total = _line_weight_total_in_main_karat(line, 'credit', main_karat_value)
    debit_total = _line_weight_total_in_main_karat(line, 'debit', main_karat_value)
    return float(credit_total - debit_total)


def _weight_kwargs_for_karat(karat, weight, side='debit'):
    """Return keyword args for create_dual_journal_entry for a single karat."""
    if not weight or weight <= 0:
        return {}
    try:
        karat_key = str(int(round(float(karat))))
    except (TypeError, ValueError):
        karat_key = str(karat)
    suffix_map = {
        '18': '18k',
        '21': '21k',
        '22': '22k',
        '24': '24k',
    }
    suffix = suffix_map.get(karat_key)
    if not suffix:
        return {}
    if side not in ('debit', 'credit'):
        side = 'debit'
    return {f"{side}_{suffix}": weight}


def _weight_kwargs_from_map(gold_map, side='debit'):
    kwargs = {}
    if not gold_map:
        return kwargs
    for karat, weight in gold_map.items():
        kwargs.update(_weight_kwargs_for_karat(karat, weight, side))
    return kwargs


# _is_manual_like_journal_entry → accounting/safe_boxes.py
# _rebuild_safe_box_transactions_for_journal_entry → accounting/safe_boxes.py
# Journal-entries domain → routes/journals.py (routes)
# (POST /journal_entries, GET /journal_entries/<id>,
#  PUT /journal_entries/<id>, POST /journal_entries/<id>/soft_delete,
#  POST /journal_entries/<id>/restore, GET /journal_entries/deleted,
#  DELETE /journal_entries/<id>)

# ============================================================================
# Reports API - Sales Overview
# ============================================================================

# Reports domain → routes/reports.py (cluster 1)
# (GET /reports/sales_overview, GET /reports/employee_scrap_ledger,
#  GET /reports/sales_by_customer, GET /reports/sales_by_item,
#  GET /reports/sales_by_karat,
#  GET /sales-race/config, PUT /sales-race/config,
#  GET /home/leaderboard, GET /general_ledger_all,
#  GET /analytics/summary, GET /reports/sales_vs_purchases_trend,
#  GET /reports/customer_balances_aging, GET /trial_balance)

# PUT /customers/<int:id> → routes/customers.py (update_customer)

# Employees domain → routes/employees.py
# (GET/POST /employees, GET/PUT/DELETE /employees/<id>,
#  PATCH /employees/<id>/photo, POST /employees/<id>/toggle-active,
#  GET /employees/<id>/payroll, GET /employees/<id>/attendance,
#  GET /employees/departments/summary,
#  GET/POST /employees/<id>/advance-account,
#  POST /employees/<id>/ensure-setup, POST /employees/bulk-ensure-setup,
#  GET /advances/summary,
#  GET/POST /payroll, GET/PUT/DELETE /payroll/<id>,
#  POST /payroll/<id>/clone, POST /payroll/bulk-approve,
#  POST /payroll/bulk-cancel, GET /payroll/payment-accounts,
#  POST /payroll/<id>/post-accrual, POST /payroll/<id>/mark-paid,
#  GET/POST /attendance, GET/PUT/DELETE /attendance/<id>)

# generate_voucher_number → accounting/voucher_engine.py (re-exported above)


def _resolve_account_id_for_amount_type(account_id, amount_type, *, safe_account_ids=None, account_cache=None):
    """Resolve the posting account id for a voucher line.

    Dual/memo rules:
    - cash lines stay on the selected account
    - gold lines should post to the memo (weight) account when the selected
      account is a financial account linked via memo_account_id.
    - never remap SafeBox accounts (they are the physical custody accounts)

    Callers that already have a precomputed safe-account-id set / Account
    cache (e.g. looping over many lines) should pass them in to avoid
    repeated queries; single-line callers can omit both and this falls back
    to querying just for that account.
    """
    if not account_id:
        return account_id
    account_id = int(account_id)

    if safe_account_ids is not None:
        if account_id in safe_account_ids:
            return account_id
    else:
        try:
            if SafeBox.query.filter_by(account_id=account_id).first():
                return account_id
        except Exception:
            pass

    if (amount_type or '').strip().lower() != 'gold':
        return account_id

    acc = account_cache.get(account_id) if account_cache is not None else None
    if acc is None:
        try:
            acc = Account.query.get(account_id)
        except Exception:
            acc = None
    if not acc:
        return account_id

    try:
        if (not bool(getattr(acc, 'tracks_weight', False))) and getattr(acc, 'memo_account_id', None):
            return int(acc.memo_account_id)
    except Exception:
        return account_id
    return account_id


# create_journal_entry_from_voucher → accounting/voucher_engine.py (re-exported above)


# _ensure_safe_box_transactions_for_invoice_je → accounting/safe_boxes.py
# _append_safe_transactions_for_voucher → accounting/voucher_engine.py (re-exported above)
# Vouchers domain → routes/vouchers.py
# (_append_safe_reversal_transactions_for_voucher helper +
#  GET /vouchers, GET /vouchers/<id>, POST /vouchers,
#  PUT /vouchers/<id>, DELETE /vouchers/<id>,
#  POST /vouchers/<id>/approve, POST /vouchers/<id>/cancel,
#  GET /vouchers/stats)

# Reports domain → routes/reports.py (cluster 2)
# (GET /reports/gold_price_history, GET /reports/gold_position)

# ========================================
# Add Bank Information to Accounts
# ========================================
# System domain → routes/system.py
# (POST /add-bank-info-to-accounts)


# ==================== Accounting Mapping Endpoints ====================

# Accounts domain → routes/accounts.py (accounting mappings)
# (GET /accounting-mappings, POST /accounting-mappings,
#  POST /accounting-mappings/batch, DELETE /accounting-mappings/<id>,
#  POST /accounting-mappings/get-account)

# System domain → routes/system.py
# (GET /app-config)


# ============================================================================
# SafeBox Routes (إدارة الخزائن)
# ============================================================================

# Safe-boxes domain → routes/safe_boxes.py (cluster B)
# (GET /safe-boxes, POST /safe-boxes, GET /safe-boxes/<id>,
#  PUT /safe-boxes/<id>, DELETE /safe-boxes/<id>,
#  GET /safe-boxes/default/<type>, GET /safe-boxes/gold/<karat>,
#  POST /safe-boxes/gold/unify,
#  POST /safe-boxes/transfer-voucher,
#  POST /safe-boxes/<id>/correct-karat)

# System domain → routes/system.py
# (POST /melting-renewal)



# =========================================================================
# BNPL Settlement (Tabby/Tamara → Bank)
# =========================================================================


# =========================================================================
# Clearing Settlement (Clearing → Bank)
# =========================================================================


# Clearing domain → routes/clearing.py
# (_compute_clearing_due_amount, _create_clearing_settlement_voucher helpers,
#  POST /clearing/settlements,
#  GET /clearing/settlements/pending-transactions,
#  POST /clearing/settlements/auto-run, create_bnpl_settlement)

# Re-exports so clearing_settlement_scheduler can import both helpers from the
# routes package without knowing the internal sub-module layout.
from routes.clearing import _create_clearing_settlement_voucher  # noqa: F401
from routes.clearing import _compute_clearing_due_amount         # noqa: F401


# ============================================================================
# Weight Closing Helpers & Office Reservations
# ============================================================================


# Office-reservations domain → routes/office_reservations.py
# (GET/POST /office-reservations,
#  GET /office-reservations/<id>,
#  POST /office-reservations/<id>/settle,
#  POST /office-reservations/<id>/cancel)


# ═══════════════════════════════════════════════════════════════
# Reports domain → routes/reports.py (cluster 3)
# (GET /dual_system/income_statement, GET /dual_system/account_statement,
#  GET /reports/income_statement, GET /reports/gram_profit,
#  GET /reports/bridge-balance-monitor,
#  GET /reports/trial-balance/cash, GET /reports/trial-balance/gold,
#  GET /reports/inventory_reconciliation,
#  GET /reports/gold-weight-trial-balance,
#  GET /reports/income-statement/gold,
#  GET /dashboard/summary-debug, GET /dashboard/admin)

# ---------------------------------------------------------------------------
# Temporary PDF hosting — used by the WhatsApp share flow.
# The Flutter client generates a PDF, uploads the bytes here, and receives
# a short-lived token. It then constructs a public URL and sends it via the
# WhatsApp deep-link API (wa.me/?text=…). Files are auto-cleaned after 24 h.
# ---------------------------------------------------------------------------

# Admin domain → routes/admin.py
# (_TEMP_PDF_DIR constants, POST/GET /temp-pdf,
#  GET/POST /admin/historical-clearing-adjustment,
#  POST /admin/historical-clearing-adjustment/<id>/apply,
#  POST /admin/historical-clearing-adjustment/<id>/cancel)

# Re-exports for test compatibility (functions moved to submodules)
from routes.vouchers import update_voucher, approve_voucher          # noqa: F401
from routes.system import (                                          # noqa: F401
    _create_postgres_backup_to_file,
    _restore_postgres_from_backup_file,
    _is_postgres_database,
    _pg_tools_available,
    _postgres_conn_parts,
)

