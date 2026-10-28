"""Gold price provider — single source of truth for current spot price.

Extracted from routes.py to break the circular dependency:
  dual_system_helpers → routes.get_current_gold_price
"""
from __future__ import annotations



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


KARATS = (18, 21, 22, 24)


class MainKaratNotSet(ValueError):
    """The settings hold no main karat (the owner, 20 Oct 2026: «يرفض العمل إن
    لم يُضبط»): nothing is weighed in the main karat on a guess. A ValueError,
    so a posting rolls back; a request is refused `main_karat_not_set` (app.py)."""

    def __init__(self):
        super().__init__('العيار الرئيسي غير مضبوط: يُضبط في الإعدادات، '
                         'ولا يُحسب وزن بالعيار الرئيسي دونه')


def configured_main_karat() -> int | None:
    """The main karat the settings hold -- None when they hold none (or one
    that is no karat). Only the settings themselves are said with it; every
    conversion reads get_main_karat()."""
    from models import Settings
    settings = Settings.query.first()
    try:
        value = int(settings.main_karat) if settings is not None and settings.main_karat is not None else None
    except (TypeError, ValueError):
        return None
    return value if value in KARATS else None


def get_main_karat() -> int:
    """The main karat -- the settings', never a fixed one (the owner, 20 Oct
    2026); MainKaratNotSet when they hold none."""
    memo = request_memo()
    if memo is not None and 'main_karat' in memo:
        return memo['main_karat']
    value = configured_main_karat()
    if value is None:
        raise MainKaratNotSet()
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

    from .office_price import KARATS as PRICED, row_gram_price

    main_karat = get_main_karat()
    price_per_gram_main_karat = 0.0
    by_karat = {}
    latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    if latest and latest.price:
        try:
            # The office's price, by the terms it was saved with (OFFICE-PRICE-1).
            price_per_gram_24k = row_gram_price(latest, 24)
            price_per_gram_main_karat = row_gram_price(latest, main_karat)
            by_karat = {karat: round(row_gram_price(latest, karat), 4) for karat in PRICED}
            updated_at = latest.date.isoformat() if latest.date else None
        except Exception as exc:
            print(f"⚠️ Failed to normalize gold price: {exc}")
            price_per_gram_24k = 0.0

    if price_per_gram_24k <= 0:
        source = "fallback"
        price_per_gram_24k = 400.0
        price_per_gram_main_karat = (price_per_gram_24k * main_karat) / 24.0
        by_karat = {karat: round(price_per_gram_24k * karat / 24.0, 4) for karat in PRICED}

    return {
        "price_per_gram_24k": round(price_per_gram_24k, 4),
        "price_per_gram_main_karat": round(price_per_gram_main_karat, 4),
        # Each karat's own: the office's are not proportional to 24k (OFFICE-PRICE-1).
        "price_per_gram_by_karat": by_karat,
        "main_karat": main_karat,
        "source": source,
        "updated_at": updated_at,
    }
