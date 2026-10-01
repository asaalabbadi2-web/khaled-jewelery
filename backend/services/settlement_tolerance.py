"""The gold settlement margin -- one place (the owner, 2 Oct 2026).

A fixed number of grams of the main karat, set in the system settings: a gold
difference within it -- the payment a little short or a little over --
counts as settled, so small margins do not hold an invoice at «partially paid».
Never below the rounding slack. Status only: the entries keep every gram.
A percent was considered and refused by the owner as impractical.
"""
from __future__ import annotations

ROUNDING_SLACK = 0.005      # grams: main-karat equivalents are kept to 2 decimals
DEFAULT_GRAMS = 0.05


def gold_settlement_tolerance() -> float:
    from models import Settings
    row = Settings.query.first()
    grams = getattr(row, 'gold_settlement_tolerance_grams', None) if row else None
    grams = DEFAULT_GRAMS if grams is None else max(0.0, float(grams))
    return max(ROUNDING_SLACK, grams)
