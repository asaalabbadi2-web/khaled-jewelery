"""Gold price provider — single source of truth for current spot price.

Extracted from routes.py to break the circular dependency:
  dual_system_helpers → routes.get_current_gold_price
"""
from __future__ import annotations

from .constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS


def request_memo() -> dict | None:
    """A dict that lives as long as the current request -- None outside one.

    The main karat is live (§13): read from Settings, never frozen. But a
    statement converts eight figures a line, and each conversion read Settings
    again: 39,540 queries for the cash customer's 4,941 lines (10 Oct 2026). One
    read per request; a change to the setting holds from the next request. Kept
    on the request itself, not on flask.g, which outlives a request when an app
    context is already pushed (the tests push one per module).
    """
    try:
        from flask import has_request_context, request
        if has_request_context():
            return request.environ.setdefault('yasargold.request_memo', {})
    except Exception:
        pass
    return None


def forget_main_karat() -> None:
    """The request that changes the setting reads the new one from here on."""
    memo = request_memo()
    if memo is not None:
        memo.pop('main_karat', None)


def get_main_karat() -> int:
    memo = request_memo()
    if memo is not None and 'main_karat' in memo:
        return memo['main_karat']
    from models import Settings
    settings = Settings.query.first()
    value = settings.main_karat if settings else 21
    if memo is not None:
        memo['main_karat'] = value
    return value


def get_current_gold_price() -> dict:
    """Return latest gold price snapshot as SAR per gram.

    Returns:
        dict with price_per_gram_24k, price_per_gram_main_karat,
        main_karat, source, updated_at
    """
    from models import GoldPrice

    price_per_gram_24k = 0.0
    source = "database"
    updated_at = None

    latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    if latest and latest.price:
        try:
            price_per_gram_24k = (latest.price / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
            updated_at = latest.date.isoformat() if latest.date else None
        except Exception as exc:
            print(f"⚠️ Failed to normalize gold price: {exc}")
            price_per_gram_24k = 0.0

    if price_per_gram_24k <= 0:
        source = "fallback"
        price_per_gram_24k = 400.0

    main_karat = get_main_karat()
    price_per_gram_main_karat = (price_per_gram_24k * main_karat) / 24.0

    return {
        "price_per_gram_24k": round(price_per_gram_24k, 4),
        "price_per_gram_main_karat": round(price_per_gram_main_karat, 4),
        "main_karat": main_karat,
        "source": source,
        "updated_at": updated_at,
    }
