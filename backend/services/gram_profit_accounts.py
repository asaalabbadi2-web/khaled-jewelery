"""The accounts gram profit reads its revenues and expenses from -- one definition (WEIGHT-CLOSE).

The owner marks them (Account.include_in_gram_profit, a parent including its
children; exclude_from_gram_profit taking one out); the weight twins of the
revenue and expense groups count too, but for the trading counterparts the
first layer already reads (the weight twins of operating revenue and cost of
sales). Moved out of the gram profit report, unchanged, so the weight-closing
position reads the same accounts the manager's dashboard does.
"""
from __future__ import annotations

from sqlalchemy import func

from models import Account


def gram_profit_accounts() -> tuple[set, set]:
    """(revenue account ids, expense account ids) that gram profit counts."""
    directly_flagged = (
        Account.query
        .filter(Account.include_in_gram_profit == True)
        .filter(func.coalesce(Account.exclude_from_gram_profit, False) == False)
        .all()
    )

    # جمع الأبناء لكل حساب مُفعّل (بحث تكراري)
    flagged_ids = {acc.id for acc in directly_flagged}

    # الحسابات المستثناة صراحةً (exclude_from_gram_profit=True)
    excluded_ids = {
        acc.id for acc in
        Account.query.filter(func.coalesce(Account.exclude_from_gram_profit, False) == True).all()
    }

    def _collect_descendants(parent_ids):
        if not parent_ids:
            return
        children = Account.query.filter(Account.parent_id.in_(parent_ids)).all()
        new_ids = set()
        for ch in children:
            if ch.id not in flagged_ids and ch.id not in excluded_ids:
                flagged_ids.add(ch.id)
                new_ids.add(ch.id)
        _collect_descendants(new_ids)

    _collect_descendants(flagged_ids.copy())

    # ── تضمين تلقائي للحسابات الوزنية التشغيلية (74xx / 75xx) ─────────────
    # نستثني مجموعتي المقابلات التجارية لأنهما محسوبتان في الطبقة ①:
    #   741xx = مقابلات المبيعات الوزنية  (Layer ① → trading_profit)
    #   751xx = مقابلات تكلفة المبيعات الوزنية (Layer ① → avg_buy)
    # ونستثني أيضاً أي حساب عليه exclude_from_gram_profit=True
    from accounting.chart_tree import (COST_OF_SALES_ROOT, EXPENSES_ROOT, OPERATING_REVENUE_ROOT,
                                       REVENUE_ROOT, role_account_id, role_subtree_ids, twin_id,
                                       twin_subtree_ids)
    # The weight twins of the operating revenue and the cost of sales groups (741, 751).
    _counterpart_roots = Account.query.filter(Account.id.in_([
        t for t in (twin_id(role_account_id(OPERATING_REVENUE_ROOT)), twin_id(role_account_id(COST_OF_SALES_ROOT)))
        if t])).all()
    # D-3 FIX: جمع كل المنحدرين بشكل مُعادي — الفلتر الضحل (parent_id) لا يرى الأحفاد
    _counterpart_all_ids: set = {a.id for a in _counterpart_roots}

    def _collect_counterpart_descendants(parent_ids: set) -> None:
        if not parent_ids:
            return
        children = Account.query.filter(Account.parent_id.in_(parent_ids)).all()
        new_ids = {ch.id for ch in children if ch.id not in _counterpart_all_ids}
        _counterpart_all_ids.update(new_ids)
        _collect_counterpart_descendants(new_ids)

    _collect_counterpart_descendants({a.id for a in _counterpart_roots})

    weight_memo_accs = (
        Account.query
        .filter(Account.id.in_(twin_subtree_ids(REVENUE_ROOT) | twin_subtree_ids(EXPENSES_ROOT)))
        .filter(Account.id.notin_(_counterpart_all_ids))
        .filter(func.coalesce(Account.exclude_from_gram_profit, False) == False)
        .all()
    )
    for _wma in weight_memo_accs:
        if _wma.id not in excluded_ids:
            flagged_ids.add(_wma.id)
    # ────────────────────────────────────────────────────────────────────────

    # إزالة المستثنيين صراحةً من النهائية
    flagged_ids -= excluded_ids

    flagged_accounts = Account.query.filter(Account.id.in_(flagged_ids)).all() if flagged_ids else []

    revenue_account_ids = set()
    expense_account_ids = set()
    # The revenue and expense groups and their weight twins, by the tree (4/74, 5/75).
    _revenue_tree = role_subtree_ids(REVENUE_ROOT) | twin_subtree_ids(REVENUE_ROOT)
    _expense_tree = role_subtree_ids(EXPENSES_ROOT) | twin_subtree_ids(EXPENSES_ROOT)
    for acc in flagged_accounts:
        if acc.id in _revenue_tree:
            revenue_account_ids.add(acc.id)
        elif acc.id in _expense_tree:
            expense_account_ids.add(acc.id)


    return revenue_account_ids, expense_account_ids
