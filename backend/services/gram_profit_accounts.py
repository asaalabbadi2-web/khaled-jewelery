"""The accounts gram profit reads its revenues and expenses from -- one definition (ADR-092).

Every revenue and expense account counts, and its weight twin with it, but
two kinds (the owner, 17 Nov 2026):
  - trading: the accounts the sale and purchase invoices post to -- known by
    their roles, never by their place -- and the twins of those; the first
    layer reads them from the invoices themselves. A weight account under the
    sales' or the cost's weight group with no cash account of its own is
    trading by its place, the one thing that says what it is. The operating revenue and
    cost of sales groups are trading too: sales were posted on 41 itself
    (January to April 2026).
  - excluded: what the owner takes out (Account.exclude_from_gram_profit),
    an account with all under it; a weight twin follows its cash account.

Until 17 Nov 2026 an account counted only when marked (include_in_gram_profit,
a parent including its children): the switch showed an account's own mark,
not whether it counted -- 20 expenses counted through 52 with their switch
off -- and a purity gain's weight twin under 741 went uncounted while its
loss was counted. That mark is no longer read.
"""
from __future__ import annotations

from typing import NamedTuple, Optional

from models import Account

COUNTED = 'counted'
TRADING = 'trading'
EXCLUDED = 'excluded'
OUTSIDE = 'outside'            # not a revenue or an expense: gram profit does not read it

# The roles of the accounts the invoices post their sales and purchases to.
TRADING_ROLES = (
    'revenue', 'sales_gold_new', 'sales_gold_scrap', 'sales_returns', 'stones_sales',
    'purchases_gold', 'purchases_gold_new', 'purchases_gold_scrap', 'purchase_returns',
    'gold_cost_of_sales', 'scrap_cost_of_sales', 'gold_cost_of_sales_weight', 'cost', 'cost_of_sales',
)


class Standing(NamedTuple):
    state: str                 # COUNTED | TRADING | EXCLUDED | OUTSIDE
    side: Optional[str]        # 'revenue' | 'expense' | None
    via: Optional[int]         # the account whose role or mark decided it (itself, a parent, its cash twin)


def gram_profit_standing() -> dict[int, Standing]:
    """Each account's standing in gram profit, and the account that decided it."""
    from accounting.chart_tree import (COST_OF_SALES_ROOT, EXPENSES_ROOT, OPERATING_REVENUE_ROOT,
                                       REVENUE_ROOT, role_account_id, role_subtree_ids, twin_subtree_ids)
    from models import AccountingMapping

    accounts = {a.id: a for a in Account.query.all()}
    revenue_tree = role_subtree_ids(REVENUE_ROOT) | twin_subtree_ids(REVENUE_ROOT)
    expense_tree = role_subtree_ids(EXPENSES_ROOT) | twin_subtree_ids(EXPENSES_ROOT)
    # a weight account's cash account: the link is kept both ways on some pairs (590 <-> 7590)
    cash_of = {a.memo_account_id: a.id for a in accounts.values() if a.memo_account_id and not a.tracks_weight}

    trading = {m.account_id for m in AccountingMapping.query.filter(
        AccountingMapping.account_type.in_(TRADING_ROLES), AccountingMapping.is_active.is_(True))}
    trading |= {role_account_id(OPERATING_REVENUE_ROOT), role_account_id(COST_OF_SALES_ROOT)}
    trading |= {accounts[t].memo_account_id for t in list(trading)
                if t in accounts and accounts[t].memo_account_id}
    # A weight account under the sales' or the cost's weight group with no cash
    # account of its own: nothing says what it is but its place -- trading,
    # not counted twice (D-3). One with a cash account follows it (7460).
    trading_weight_groups = twin_subtree_ids(OPERATING_REVENUE_ROOT) | twin_subtree_ids(COST_OF_SALES_ROOT)
    unlinked_trading = {i for i in trading_weight_groups if i not in cash_of}

    def marked_above(account_id: int) -> Optional[int]:
        """The account whose mark takes *account_id* out: itself or a parent."""
        seen, node = set(), accounts.get(account_id)
        while node is not None and node.id not in seen:
            seen.add(node.id)
            if node.exclude_from_gram_profit:
                return node.id
            node = accounts.get(node.parent_id)
        return None

    def excluded_by(account_id: int) -> Optional[int]:
        """Its own or a parent's mark -- or, a weight twin, its cash account's."""
        by = marked_above(account_id)
        cash = cash_of.get(account_id)
        return by if by is not None or cash is None else marked_above(cash)

    standing = {}
    for account_id in accounts:
        side = 'revenue' if account_id in revenue_tree else 'expense' if account_id in expense_tree else None
        if side is None:
            standing[account_id] = Standing(OUTSIDE, None, None)
        elif account_id in trading:
            standing[account_id] = Standing(TRADING, side, cash_of.get(account_id, account_id))
        elif account_id in unlinked_trading:
            standing[account_id] = Standing(TRADING, side, account_id)
        elif (by := excluded_by(account_id)) is not None:
            standing[account_id] = Standing(EXCLUDED, side, by)
        else:
            standing[account_id] = Standing(COUNTED, side, None)
    return standing


def gram_profit_accounts() -> tuple[set, set]:
    """(revenue account ids, expense account ids) that gram profit counts."""
    standing = gram_profit_standing()
    counted = {i: s for i, s in standing.items() if s.state == COUNTED}
    return ({i for i, s in counted.items() if s.side == 'revenue'},
            {i for i, s in counted.items() if s.side == 'expense'})


def standing_view(account_id: int, standing: dict, accounts: dict) -> dict:
    """What the accounts screen shows: counted or not, and the account that decided it."""
    s = standing.get(account_id) or Standing(OUTSIDE, None, None)
    via = accounts.get(s.via) if s.via is not None and s.via != account_id else None
    return {'state': s.state, 'side': s.side,
            'via': {'id': via.id, 'account_number': via.account_number, 'name': via.name} if via else None}
