"""What each setting is, for its record and its save (ADR-102) -- POLICY, the owner's.

The level says what a change asks (spec v2 §8): 1 an ordinary setting, 2 one
that changes how documents are made, 3 one that changes the books -- its
reason is required through PATCH /settings. The type says how two values are
compared: a value set to what it was by its type is not a change, and records
nothing. What is recorded of a value: 'full', or 'hash' for a large one (the
logo), or 'none' for anything secret -- there is none in Settings today.

Keys not listed are level 1 of their column's type. The inventory these come
from: the settings spec's inventory (25 Nov 2026), read from the code.
"""
from __future__ import annotations

import hashlib
import json
from datetime import date, datetime
from decimal import Decimal, ROUND_HALF_UP

LEVEL_3 = frozenset({
    'main_karat', 'manufacturing_wage_mode',
    'tax_rate', 'tax_enabled', 'sales_vat_enabled', 'vat_exempt_karats',
    'employee_cash_safes_enabled', 'employee_gold_safes_enabled',
    'main_cash_safe_box_id', 'sale_gold_safe_box_id', 'main_scrap_gold_safe_box_id',
    'stones_pending_account_id', 'stones_display_revenue_account_id',
    'auto_post_invoices', 'auto_post_entries', 'require_approval_before_post', 'allow_unposting',
    'voucher_auto_post',
    'office_main_fees_usd', 'office_custom_fees_usd', 'office_discount_21', 'office_discount_18',
    'weight_closing_settings', 'payroll_policy',
    'bonus_expense_account_number', 'bonus_payable_account_number',
})
LEVEL_2 = frozenset({
    'company_tax_number',
    'default_discount_rate', 'allow_discount', 'allow_manual_invoice_items', 'require_auth_for_invoice_create',
    'idle_timeout_enabled', 'idle_timeout_minutes', 'allow_partial_invoice_payments',
    'receiving_weight_tolerance', 'piece_split_tolerance', 'coding_rest_tolerance',
    'gold_settlement_tolerance_grams', 'buy_price_ratio',
    'accountant_approval_limit_cash', 'accountant_approval_limit_gold_grams',
    'backup_auto_enabled', 'backup_auto_mode', 'backup_auto_time', 'backup_auto_interval_minutes',
    'backup_retention_count', 'password_policy',
    'weekly_sales_target_weight', 'monthly_sales_target_weight', 'sales_race_settings',
    'coding_on',
})

MONEY = frozenset({'office_main_fees_usd', 'office_custom_fees_usd', 'office_discount_21', 'office_discount_18',
                   'accountant_approval_limit_cash'})
GRAMS = frozenset({'receiving_weight_tolerance', 'piece_split_tolerance', 'coding_rest_tolerance',
                   'gold_settlement_tolerance_grams', 'accountant_approval_limit_gold_grams',
                   'weekly_sales_target_weight', 'monthly_sales_target_weight'})
JSON_TEXT = frozenset({'vat_exempt_karats', 'print_template_by_invoice_type', 'weight_closing_settings',
                       'password_policy', 'sales_race_settings', 'payroll_policy'})
HASHED = frozenset({'company_logo_base64'})
SECRET: frozenset = frozenset()          # none in Settings today; a secret added later is listed here

# Columns a record is not kept of: the row's own bookkeeping.
NOT_RECORDED = frozenset({'id', 'created_at', 'updated_at'})


def level(key: str) -> int:
    return 3 if key in LEVEL_3 else 2 if key in LEVEL_2 else 1


def _canonical_json(value):
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except (TypeError, ValueError):
            return value
    if isinstance(value, list):
        try:
            value = sorted(value, key=lambda v: json.dumps(v, sort_keys=True, default=str))
        except TypeError:
            pass
    return json.dumps(value, sort_keys=True, ensure_ascii=False, default=str)


def _quantize(value, places: str):
    try:
        return Decimal(str(value)).quantize(Decimal(places), rounding=ROUND_HALF_UP)
    except Exception:
        return value


def same(key: str, a, b) -> bool:
    """Whether *a* and *b* are one value of *key* by its type."""
    if a is None or b is None:
        return a is None and b is None
    if key in MONEY:
        return _quantize(a, '0.01') == _quantize(b, '0.01')
    if key in GRAMS:
        return _quantize(a, '0.001') == _quantize(b, '0.001')
    if key in JSON_TEXT:
        return _canonical_json(a) == _canonical_json(b)
    if isinstance(a, str) and isinstance(b, str):
        return a.strip() == b.strip()
    if isinstance(a, float) or isinstance(b, float):
        try:
            return float(a) == float(b)
        except (TypeError, ValueError):
            return False
    return a == b


def recorded(key: str, value) -> str:
    """The value as the change log keeps it: JSON text, its hash, or nothing."""
    if key in SECRET:
        return json.dumps(None)
    if key in HASHED and value is not None:
        return json.dumps('sha256:' + hashlib.sha256(str(value).encode('utf-8')).hexdigest())
    if isinstance(value, (date, datetime)):
        value = value.isoformat()
    return json.dumps(value, ensure_ascii=False, default=str)
