"""Accounting mappings -- an account is found by its role (AccountingMapping), never by its number (CHART-002)."""
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

# The roles the postings ask for, by operation -- each must resolve to a mapped
# account (directly or through the default operation). Measured from every call
# the code and the suite make, on the production copy (14 Oct 2026). A role the
# code starts asking for joins this list; ROLE_NOT_MAPPED reports any that do
# not resolve -- a new year's database starts with all of them (ADR-044).
REQUIRED_ROLES = (
    *((DEFAULT_MAPPING_OPERATION_TYPE, r) for r in ('inventory_count_shortage', 'inventory_count_surplus')),
    *(('بيع', r) for r in ('cash', 'commission', 'commission_vat', 'manufacturing_wage', 'revenue',
                           'sales_gold_new', 'sales_gold_scrap', 'vat_payable', 'vat_receivable')),
    *(('تسوية_مورد', r) for r in ('supplier_settlement_expense', 'supplier_settlement_income',
                                  'supplier_weight_settlement_expense', 'supplier_weight_settlement_income')),
    *(('شراء', r) for r in ('cash', 'manufacturing_wage_inventory', 'purchases_gold', 'suppliers',
                            'vat_receivable')),
    *(('شراء من عميل', r) for r in ('cash', 'purchases_gold', 'purchases_gold_new',
                                    'purchases_gold_scrap', 'vat_receivable')),
    *(('مرتجع بيع', r) for r in ('cash', 'customers', 'manufacturing_wage', 'sales_returns')),
    *(('مرتجع شراء', r) for r in ('cash', 'customers', 'purchase_returns')),
    ('مرتجع شراء (مورد)', 'purchase_returns'),
    # The gold's cost of sales, in cash and in weight: a return reverses its
    # cost on the first; a purchase's weight falls back on the second (CHART-002).
    (DEFAULT_MAPPING_OPERATION_TYPE, 'gold_cost_of_sales'),
    (DEFAULT_MAPPING_OPERATION_TYPE, 'gold_cost_of_sales_weight'),
    # The employee structure (services/employee_accounts.py): the parents an
    # employee's accounts are made under, and the payroll and bonus expenses.
    *((DEFAULT_MAPPING_OPERATION_TYPE, r) for r in (
        'employee_personal_parent', 'employee_salary_payable_parent', 'employee_commission_payable_parent',
        'employee_eos_payable_parent', 'employee_bonus_payable_parent', 'employee_gold_custody_parent',
        'employee_cash_custody_parent', 'salary_expense', 'bonus_expense')),
    # The gold's financial inventory -- one account for every karat, new apart
    # from scrap -- the weight closing's bridge, and the karat-difference
    # commission earned and paid (CHART-002 step 4).
    *((DEFAULT_MAPPING_OPERATION_TYPE, r) for r in (
        'gold_inventory_new', 'gold_inventory_scrap', 'weight_closing_bridge',
        'karat_diff_revenue', 'karat_diff_expense')),
)


def unmapped_roles() -> list:
    """The required roles no mapping resolves -- what a posting would be refused."""
    return [(op, role) for op, role in REQUIRED_ROLES if not get_account_id_for_mapping(op, role)]


class AccountNotMapped(ValueError):
    """An amount to post on a role no mapping resolves (CHART-002, ADR-046): the
    posting is refused -- a ValueError, so the invoice rolls back and says why."""

    def __init__(self, operation_type, role, message=None):
        self.operation_type, self.role = operation_type, role
        super().__init__(message or f'لا حساب مربوط للدور ({operation_type} / {role}): '
                                    f'يُضبط في «الربط المحاسبي»، ولا يُرحَّل القيد دونه')


class VatAccountNotMapped(AccountNotMapped):
    """A VAT amount with no account mapped for its role (ADR-043 rule 4)."""

    def __init__(self, operation_type, role):
        super().__init__(operation_type, role,
                         f'حساب الضريبة غير مربوط ({operation_type} / {role}): '
                         f'يُضبط في الربط المحاسبي، ولا يُرحَّل قيد بضريبة دونه')


def require_account(operation_type, role) -> int:
    """The account mapped for a role -- or the posting is refused (ADR-046)."""
    account_id = get_account_id_for_mapping(operation_type, role)
    if not account_id:
        raise AccountNotMapped(operation_type, role)
    return account_id


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

    # No number, no name, no account created on the fly stands in for a role
    # (CHART-002, the owner 14 Oct 2026): a role is its mapping or nothing. The
    # 33 numbers and 10 names that stood in -- some stale (24k inventory fell
    # back on 1200, the customers) -- became mappings where production used
    # them (migration 20261014_roles_mapped); a role still unmapped is reported
    # nightly (ROLE_NOT_MAPPED) and refused where the posting asks for it.
    return None
