"""The chart as a tree: an account and everything under it (CHART-002 step 4b2).

Readers classified accounts by their number's prefix -- '21%' for what is owed
to suppliers, '12%' for what customers owe. A prefix is a numbering scheme, and
2027 renumbers (ADR-044); the tree is the chart's own answer. A group a reader
needs is a role (accounting_mapping), and its accounts are that account's
subtree.
"""
from __future__ import annotations

from collections import defaultdict

from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
from models import Account

SUPPLIER_PAYABLES_ROOT = 'supplier_payables_root'       # 21 «الموردون» on production
CUSTOMER_RECEIVABLES_ROOT = 'customer_receivables_root'  # 120 «العملاء» on production

# The chart's groups the reports read (CHART-002 release 5). A weight group is
# the linked twin of its financial group (74 of 4, 751 of 51...): twin_subtree_ids.
ASSETS_ROOT = 'assets_root'                              # 1 «الأصول»
LIABILITIES_ROOT = 'liabilities_root'                    # 2 «الخصوم»
EQUITY_ROOT = 'equity_root'                              # 3 «حقوق الملكية»
REVENUE_ROOT = 'revenue_root'                            # 4 «الإيرادات»
EXPENSES_ROOT = 'expenses_root'                          # 5 «المصروفات»
OPERATING_REVENUE_ROOT = 'operating_revenue_root'        # 41 «إيرادات النشاط»
COST_OF_SALES_ROOT = 'cost_of_sales_root'                # 51 «تكلفة المبيعات»
OPERATING_EXPENSES_ROOT = 'operating_expenses_root'      # 52 «مصاريف تشغيلية»
GOLD_INVENTORY_ROOT = 'gold_inventory_root'              # 130 «المخزون»
WORKED_GOLD_SUPPLIERS_ROOT = 'worked_gold_suppliers_root'  # 210 «موردو الذهب المشغول»
VALUATION_EQUITY = 'valuation_equity'                    # 33 «فروقات تقييم الذهب»
CASH_ROOT = 'cash_root'                                  # 1100 «النقدية»: its twin, the cash weight side

GROUP_ROLES = (ASSETS_ROOT, LIABILITIES_ROOT, EQUITY_ROOT, REVENUE_ROOT, EXPENSES_ROOT, OPERATING_REVENUE_ROOT,
               COST_OF_SALES_ROOT, OPERATING_EXPENSES_ROOT, GOLD_INVENTORY_ROOT, WORKED_GOLD_SUPPLIERS_ROOT,
               VALUATION_EQUITY, CASH_ROOT)
ROOT_ROLES = (SUPPLIER_PAYABLES_ROOT, CUSTOMER_RECEIVABLES_ROOT, *GROUP_ROLES)


def subtree_ids(*root_ids: int) -> set[int]:
    """The accounts under *root_ids*, the roots included."""
    children = defaultdict(list)
    for account_id, parent_id in Account.query.with_entities(Account.id, Account.parent_id).all():
        if parent_id is not None:
            children[parent_id].append(account_id)
    found, stack = set(), [int(r) for r in root_ids if r is not None]
    while stack:
        node = stack.pop()
        if node not in found:
            found.add(node)
            stack.extend(children.get(node, ()))
    return found


def role_subtree_ids(role: str) -> set[int]:
    """The subtree of the account a root role is mapped to -- or AccountNotMapped."""
    return subtree_ids(require_account(DEFAULT_MAPPING_OPERATION_TYPE, role))


def role_account_id(role: str) -> int:
    """The account a role is mapped to -- or AccountNotMapped."""
    return require_account(DEFAULT_MAPPING_OPERATION_TYPE, role)


def twin_id(account_id: int) -> int | None:
    """An account's linked weight twin -- by its link, never its number."""
    from models import db
    account = db.session.get(Account, account_id)
    return account.memo_account_id if account is not None else None


def twin_subtree_ids(role: str) -> set[int]:
    """The subtree of the weight twin of the account *role* is mapped to: the
    weight side of a financial group (74 under 4's role, 751 under 51's).
    A group with no linked twin has no weight side: empty."""
    twin = twin_id(role_account_id(role))
    return subtree_ids(twin) if twin else set()
