"""The buy price -- the market's price times the settings' ratio (PRICE-BUY-1).

One place computes it: the home price card shows it and the scrap purchase
screen falls back to it; before, each multiplied by a 0.98 of its own. The ratio
is policy (settings.buy_price_ratio, the owner edits it), the arithmetic a law
(here, tested in tests/test_buy_price.py).
"""
from __future__ import annotations

from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS

KARATS = (18, 21, 22, 24)
DEFAULT_RATIO = 0.98


def buy_price_ratio() -> float:
    from core.settings import _get_settings_singleton
    settings = _get_settings_singleton(create_if_missing=False)
    ratio = getattr(settings, 'buy_price_ratio', None) if settings is not None else None
    return float(ratio) if ratio else DEFAULT_RATIO


def gram_prices(price_usd_per_oz: float, ratio: float | None = None) -> dict:
    """{'18': {'sell': .., 'buy': ..}, '21': .., '22': .., '24': ..} in SAR per gram."""
    ratio = buy_price_ratio() if ratio is None else float(ratio)
    gram_24 = (float(price_usd_per_oz or 0.0) / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
    out = {}
    for karat in KARATS:
        sell = gram_24 * karat / 24.0
        out[str(karat)] = {'sell': round(sell, 2), 'buy': round(sell * ratio, 2)}
    return out
