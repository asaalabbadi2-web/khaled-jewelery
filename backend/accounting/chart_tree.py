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
ROOT_ROLES = (SUPPLIER_PAYABLES_ROOT, CUSTOMER_RECEIVABLES_ROOT)


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
