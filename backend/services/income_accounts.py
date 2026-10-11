"""The income statement's three groups -- as the chart of accounts names them.

Revenue is group 4 and everything under it. Cost of sales is 51 «تكلفة
المبيعات» and everything under it (manufacturing wages 510, scrap purchases
512, the cost of gold sold 521). Operating expenses are the rest of group 5.
The income statement classified by number prefixes -- «50», «52», «520» as
cost of sales, which is the chart's operating group, and 51 with its children
as operating -- so 2026's gross profit (18.4 million) exceeded its revenue
(11.1 million) on the 10 Oct copy (the owner, 11 Oct 2026).

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

REVENUE_ROOT = '4'
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


def _tree():
    rows = Account.query.with_entities(Account.id, Account.parent_id, Account.account_number).all()
    children_of: dict[int, list[int]] = {}
    ids_by_number: dict[str, int] = {}
    for account_id, parent_id, number in rows:
        ids_by_number[str(number or '').strip()] = account_id
        if parent_id is not None:
            children_of.setdefault(parent_id, []).append(account_id)
    return children_of, ids_by_number


def income_account_groups() -> dict[str, set[int]]:
    """{'revenue', 'cost_of_sales', 'operating'}: account ids, by the tree."""
    children_of, ids_by_number = _tree()
    expenses = _subtree_ids(EXPENSES_ROOT, children_of, ids_by_number)
    cost_of_sales = _subtree_ids(COST_OF_SALES_ROOT, children_of, ids_by_number)
    return {
        'revenue': _subtree_ids(REVENUE_ROOT, children_of, ids_by_number),
        'cost_of_sales': cost_of_sales,
        'operating': expenses - cost_of_sales,
    }


def operating_expense_account_ids() -> set[int]:
    """Group 5 and everything under it, less 51 and everything under it."""
    return income_account_groups()['operating']
