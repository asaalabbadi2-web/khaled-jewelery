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

from accounting.chart_tree import COST_OF_SALES_ROOT, EXPENSES_ROOT, REVENUE_ROOT, role_subtree_ids


def income_account_groups() -> dict[str, set[int]]:
    """{'revenue', 'cost_of_sales', 'operating'}: account ids, by the tree under
    the group roles (CHART-002 release 5: 4, 5 and 51 were numbers here)."""
    expenses = role_subtree_ids(EXPENSES_ROOT)
    cost_of_sales = role_subtree_ids(COST_OF_SALES_ROOT)
    return {
        'revenue': role_subtree_ids(REVENUE_ROOT),
        'cost_of_sales': cost_of_sales,
        'operating': expenses - cost_of_sales,
    }


def operating_expense_account_ids() -> set[int]:
    """The expenses group and everything under it, less the cost of sales group."""
    return income_account_groups()['operating']
