"""The buy price -- the market's price times the settings' ratio (PRICE-BUY-1).

The market's price is the closing office's (OFFICE-PRICE-1).

One place computes it: the home price card shows it and the scrap purchase
screen falls back to it; before, each multiplied by a 0.98 of its own. The ratio
is policy (settings.buy_price_ratio, the owner edits it), the arithmetic a law
(here, tested in tests/test_buy_price.py).
"""
from __future__ import annotations

from pricing.office_price import KARATS, gram_price
DEFAULT_RATIO = 0.98


def buy_price_ratio() -> float:
    from core.settings import _get_settings_singleton
    settings = _get_settings_singleton(create_if_missing=False)
    ratio = getattr(settings, 'buy_price_ratio', None) if settings is not None else None
    return float(ratio) if ratio else DEFAULT_RATIO


def gram_prices(price_usd_per_oz: float, ratio: float | None = None, terms=None) -> dict:
    """{'18': {'sell': .., 'buy': ..}, '21': .., '22': .., '24': ..} in SAR per gram:
    the office's price by *terms* (pricing/office_price.py), by the ounce without."""
    ratio = buy_price_ratio() if ratio is None else float(ratio)
    out = {}
    for karat in KARATS:
        sell = gram_price(price_usd_per_oz, karat, terms)
        out[str(karat)] = {'sell': round(sell, 2), 'buy': round(sell * ratio, 2)}
    return out


def row_prices(row, ratio: float | None = None) -> dict:
    """gram_prices of a saved price, with its own terms."""
    from pricing.office_price import terms_of
    return gram_prices(getattr(row, 'price', 0.0), ratio, terms_of(row))


def _move(now, opening) -> dict:
    if now is None or not opening:
        return {'change': None, 'change_percent': None}
    change = float(now) - float(opening)
    return {'change': round(change, 2), 'change_percent': round(change / float(opening) * 100, 2)}


def price_moves(now: dict, opening: dict) -> dict:
    """{'21': {'change', 'change_percent', 'spread'}}: each karat's selling price
    since the day's opening -- its own, by its own terms (OFFICE-PRICE-1) -- and
    its sell less its buy. The screens show these; they compute none (the owner,
    13 Nov 2026)."""
    out = {}
    for karat, row in (now or {}).items():
        opened = ((opening or {}).get(karat) or {}).get('sell')
        sell, buy = row.get('sell'), row.get('buy')
        out[karat] = {**_move(sell, opened),
                      'spread': round(float(sell) - float(buy), 2) if sell is not None and buy is not None else None}
    return out


def ounce_move(now, opening) -> dict:
    """The world ounce's own move since the day's opening, in dollars."""
    return _move(now, opening)
