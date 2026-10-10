"""Karat conversion — the gold-weight math layer.

Single source of truth for converting weights between karats.
All domains import from here; routes/__init__.py re-exports for backward compat.
"""
from __future__ import annotations

from pricing.gold_price_service import get_main_karat  # noqa: F401 — re-exported
from core.number_helpers import coerce_float as _cf


def convert_to_main_karat(weight, karat):
    """Convert *weight* grams at *karat* to equivalent grams at the system main karat."""
    main = _cf(get_main_karat(), 0.0)
    k = _cf(karat, 0.0)
    if k == 0 or main == 0:
        return 0
    return (weight * k) / main


def convert_from_main_karat(weight, karat):
    """Convert *weight* grams at main karat back to *karat* grams."""
    main = _cf(get_main_karat(), 0.0)
    k = _cf(karat, 0.0)
    if k == 0:
        return 0
    return (weight * main) / k


def by_karat_in_main_karat(by_karat: dict) -> float:
    """{'18k': g, '21k': g, '22k': g, '24k': g} as grams at the main karat."""
    return sum(convert_to_main_karat(float(by_karat.get(f'{k}k') or 0.0), k) for k in (18, 21, 22, 24))
