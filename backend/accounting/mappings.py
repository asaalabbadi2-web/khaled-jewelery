"""Accounting mappings — account resolution from AccountingMapping config and default fallbacks."""
from __future__ import annotations

from models import db, Account, AccountingMapping


DEFAULT_MAPPING_OPERATION_TYPE = 'افتراضي'

# Module-level cache — shared reference; routes/__init__.py re-exports this dict so any
# code that writes to _ACCOUNT_NUMBER_CACHE via routes namespace mutates the same object.
_ACCOUNT_NUMBER_CACHE: dict[str, int | None] = {}


def get_account_id_by_number(account_number) -> int | None:
    """Fast lookup for account.id using its structured account number."""
    if not account_number:
        return None
    key = str(account_number)
    if key in _ACCOUNT_NUMBER_CACHE:
        return _ACCOUNT_NUMBER_CACHE[key]
    account = Account.query.filter_by(account_number=key).first()
    account_id = account.id if account else None
    _ACCOUNT_NUMBER_CACHE[key] = account_id
    return account_id


VAT_ROLES = ('vat_payable', 'vat_receivable', 'commission_vat')


class VatAccountNotMapped(ValueError):
    """A VAT amount with no account mapped for its role (ADR-043 rule 4)."""

    def __init__(self, operation_type, role):
        self.operation_type, self.role = operation_type, role
        super().__init__(f'حساب الضريبة غير مربوط ({operation_type} / {role}): '
                         f'يُضبط في الربط المحاسبي، ولا يُرحَّل قيد بضريبة دونه')


def require_vat_account(operation_type, role) -> int:
    """The account mapped for a VAT role -- or the posting is refused (ADR-043 rule 4)."""
    account_id = get_account_id_for_mapping(operation_type, role)
    if not account_id:
        raise VatAccountNotMapped(operation_type, role)
    return account_id


def get_account_id_for_mapping(operation_type, account_type) -> int | None:
    """
    الحصول على معرف الحساب المحاسبي لعملية معينة

    Args:
        operation_type: نوع العملية (بيع، شراء، مرتجع...)
        account_type: نوع الحساب (inventory_21k, cash, revenue...)

    Returns:
        int: معرف الحساب المحاسبي، أو None إذا لم يتم العثور عليه

    الدالة تحاول:
    1. البحث في إعدادات الربط المخصصة (AccountingMapping)
    2. إذا لم تجد، تستخدم الحسابات الافتراضية
    """
    # Support legacy/UI alias keys.
    _alias_map = {
        'cost_of_sales': ['cost'],
        'cost': ['cost_of_sales'],
        'sales_gold_new': ['revenue'],
        'revenue': ['sales_gold_new'],
    }

    candidates = [account_type]
    try:
        for alt in (_alias_map.get(account_type) or []):
            if alt and alt not in candidates:
                candidates.append(alt)
    except Exception:
        candidates = [account_type]

    # 1. محاولة الحصول على الحساب من الإعدادات المخصصة
    for ct in candidates:
        mapping = db.session.query(AccountingMapping).filter_by(
            operation_type=operation_type,
            account_type=ct,
            is_active=True
        ).first()
        if mapping:
            return mapping.account_id

    # 2. fallback للربط الافتراضي العام
    if operation_type != DEFAULT_MAPPING_OPERATION_TYPE:
        for ct in candidates:
            default_mapping = db.session.query(AccountingMapping).filter_by(
                operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                account_type=ct,
                is_active=True
            ).first()
            if default_mapping:
                return default_mapping.account_id

    def _first_existing_account_id_by_numbers(numbers):
        for n in numbers:
            if n in (None, '', False):
                continue
            acc = Account.query.filter_by(account_number=str(n)).first()
            if acc:
                return acc.id
        return None

    def _first_existing_account_id_by_names(names):
        for nm in names:
            if not nm:
                continue
            acc = Account.query.filter_by(name=str(nm)).first()
            if acc:
                return acc.id
        return None

    # 3. fallback لأرقام افتراضية داخلية
    DEFAULT_ACCOUNT_NUMBER_CANDIDATES = {
        'inventory_18k': ['1300'],
        'inventory_21k': ['1220', '1310'],
        'inventory_22k': ['1320'],
        'inventory_24k': ['1200', '1330', '1340'],
        'manufacturing_wage_inventory': ['1340', '1350', '1320'],
        'inventory_weight_18k': ['71300', '7300'],
        'inventory_weight_21k': ['71310', '7310'],
        'inventory_weight_22k': ['71320', '7320'],
        'inventory_weight_24k': ['71330', '7330'],
        'cash': ['15', '1100'],
        'bank': ['1110'],
        'bank_rajhi': ['1120'],
        'customers': ['1200'],
        'customers_scrap': ['1210'],
        'suppliers': ['210'],
        'suppliers_processed': ['220'],
        'revenue': ['400', '40'],
        'sales_gold_new': ['400', '40'],
        'sales_gold_scrap': ['401'],
        'sales_wage': ['41'],
        'sales_returns': ['420', '400', '40'],
        'purchases_gold': ['511', '512', '510', '51'],
        'purchases_gold_new': ['511', '510', '51'],
        'purchases_gold_scrap': ['512', '511', '510'],
        'cost': ['521', '50'],
        'cost_of_sales': ['521', '50'],
        'purchase_returns': ['513', '512', '511', '50'],
        # No number stands in for a VAT role (ADR-043 rule 4): 2210 took three
        # April 2026 returns' VAT, and 1500 is «مدى». See require_vat_account.
        'commission': ['5150'],
        'operating_expenses': ['51'],
        'capital': ['31'],
        'retained_earnings': ['32'],
        'supplier_bridge': [None],
        'manufacturing_wage': ['510'],
    }

    DEFAULT_ACCOUNT_NAME_CANDIDATES = {
        'cash': ['صندوق النقدية'],
        'sales_gold_new': ['مبيعات ذهب جديد'],
        'sales_gold_scrap': ['مبيعات ذهب كسر'],
        'revenue': ['مبيعات ذهب جديد'],
        'cost_of_sales': ['تكلفة مبيعات الذهب'],
        'cost': ['تكلفة مبيعات الذهب'],
        'inventory_21k': ['مخزون ذهب عيار 21'],
        'inventory_24k': ['مخزون ذهب عيار 24'],
        'suppliers': ['موردو ذهب'],
        'customers': ['أرصدة ذهب العملاء'],
    }

    for ct in candidates:
        numbers = DEFAULT_ACCOUNT_NUMBER_CANDIDATES.get(ct)
        if numbers:
            hit = _first_existing_account_id_by_numbers(numbers)
            if hit:
                return hit

        names = DEFAULT_ACCOUNT_NAME_CANDIDATES.get(ct)
        if names:
            hit = _first_existing_account_id_by_names(names)
            if hit:
                return hit

    if account_type == 'manufacturing_wage':
        # Lazy import to break the wages ↔ mappings cycle (wages imports mappings at module level).
        from accounting.wages import _ensure_manufacturing_wage_expense_account
        return _ensure_manufacturing_wage_expense_account()

    return None
