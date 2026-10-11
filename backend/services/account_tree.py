"""A parent account's balance: its own entries and every descendant's (CHART-UI-1).

The chart screen summed a parent from its children on the device and left the
parent's own entries out -- nine parents on the production copy carry their
own, 41 «إيرادات النشاط» (-4,896,846.99) among them. A balance is the server's.
"""
from __future__ import annotations

from collections import defaultdict

from pricing.karat_service import convert_to_main_karat

KARATS = (18, 21, 22, 24)


def subtree_balances(parent_of: dict[int, int | None], own: dict[int, dict]) -> dict[int, dict]:
    """{parent id: {'cash', '18k'.. '24k', 'weight_total'}} for every account
    with children -- its own balance plus all its descendants'. *own* is the
    live balance by account: {'cash', '18k', '21k', '22k', '24k'}."""
    children = defaultdict(list)
    for account_id, parent_id in parent_of.items():
        if parent_id is not None and parent_id in parent_of:
            children[parent_id].append(account_id)
    memo: dict[int, dict] = {}

    def total(account_id):
        if account_id in memo:
            return memo[account_id]
        mine = own.get(account_id) or {}
        out = {'cash': float(mine.get('cash') or 0.0), **{f'{k}k': float(mine.get(f'{k}k') or 0.0) for k in KARATS}}
        for child in children.get(account_id, ()):
            sub = total(child)
            for key in out:
                out[key] += sub[key]
        memo[account_id] = out
        return out

    result = {}
    for account_id in children:
        t = total(account_id)
        result[account_id] = {
            'cash': round(t['cash'], 2),
            **{f'{k}k': round(t[f'{k}k'], 3) for k in KARATS},
            'weight_total': round(sum(convert_to_main_karat(t[f'{k}k'], k) for k in KARATS), 3),
        }
    return result
