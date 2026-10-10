"""Which accounts are operating expenses -- as the chart of accounts names them.

Group 5 «المصروفات» holds two things: 51 «تكلفة المبيعات» (manufacturing
wages 510, scrap purchases 512, the cost of gold sold 521, ...) and the
operating expenses -- 52 «مصاريف تشغيلية» with its manufacturing, selling and
administrative children, and anything else under 5. The dashboard's
«المصروفات» summed every 5-account: 18,995,723.96 for 2026 against about
777,000 of operating expense (the owner, 11 Oct 2026: operating only).

By the tree, not by number prefixes: an account moved under 51 stops being an
operating expense without a code change.
"""
from __future__ import annotations

from models import Account

EXPENSES_ROOT = '5'
COST_OF_SALES_ROOT = '51'


def _subtree_ids(root_number: str, children_of: dict, ids_by_number: dict) -> set[int]:
    root = ids_by_number.get(root_number)
    if root is None:
        return set()
    found, stack = set(), [root]
    while stack:
        node = stack.pop()
        if node in found:
            continue
        found.add(node)
        stack.extend(children_of.get(node, ()))
    return found


def operating_expense_account_ids() -> set[int]:
    """Group 5 and everything under it, less 51 and everything under it."""
    rows = Account.query.with_entities(Account.id, Account.parent_id, Account.account_number).all()
    children_of: dict[int, list[int]] = {}
    ids_by_number: dict[str, int] = {}
    for account_id, parent_id, number in rows:
        ids_by_number[str(number or '').strip()] = account_id
        if parent_id is not None:
            children_of.setdefault(parent_id, []).append(account_id)
    return (_subtree_ids(EXPENSES_ROOT, children_of, ids_by_number)
            - _subtree_ids(COST_OF_SALES_ROOT, children_of, ids_by_number))
