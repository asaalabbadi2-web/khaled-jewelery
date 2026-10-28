"""The gold price is the closing office's, not the world ounce's (OFFICE-PRICE-1).

The owner, 28 Oct 2026: the shop closes at the offices' price -- Dewan Al Dahab
(dewanaldahab.com/ar/LivePricing) -- so what sales and purchases are priced
from is that price. Its formula, read from its own page and matched to its
figures to the halala (28 Oct 2026, 22:05 UTC):

    24k a kilo  = (ounce + main fees + custom fees) x 32.148 x 3.75
    24k a gram  = the kilo, to the riyal, / 1000
    21k a gram  = the kilo / 1143 - the 21k discount
    18k a gram  = the kilo / 1333 - the 18k discount
    22k a gram  = 21k x 22/21                       (the owner: from 21k)

The arithmetic is the law (here, tests/test_office_price.py); the fees and the
discounts are policy -- the settings', the owner's (1.35, 43, 0.75 and 1 then).

A day's price is a fact (§13, frozen): each saved price carries the terms it
was saved with, and is priced by them. A price saved before there were terms
carries none and is priced as it was, by the ounce. Every gram price in the
server comes from here; tests/test_office_price.py fails a conversion of the
ounce anywhere else.
"""
from __future__ import annotations

from dataclasses import dataclass

from .constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS

KARATS = (18, 21, 22, 24)
# The office's own figures, not the definitions: a kilo is 32.1507 troy ounces,
# and 1000 x 24/21 is 1142.86. Its price is what it is.
OUNCES_PER_KILO = 32.148
KILO_PER_GRAM_21 = 1143
KILO_PER_GRAM_18 = 1333


@dataclass(frozen=True)
class OfficeTerms:
    main_fees_usd: float
    custom_fees_usd: float
    discount_21: float
    discount_18: float

    def kilo_24(self, ounce: float) -> float:
        return (float(ounce) + self.main_fees_usd + self.custom_fees_usd) * OUNCES_PER_KILO * SAR_USD_PEG

    def gram(self, ounce: float, karat: int) -> float:
        kilo = self.kilo_24(ounce)
        karat = int(karat)
        if karat == 24:
            return round(kilo) / 1000.0
        if karat == 18:
            return kilo / KILO_PER_GRAM_18 - self.discount_18
        gram_21 = kilo / KILO_PER_GRAM_21 - self.discount_21
        if karat == 21:
            return gram_21
        if karat == 22:
            return gram_21 * 22/21          # fineness to fineness, as the owner said: from 21k
        raise ValueError(f'no office price for karat {karat}')


def gram_price(ounce: float | None, karat: int, terms: OfficeTerms | None) -> float:
    """SAR a gram of *karat*: the office's by *terms*, or by the ounce when a
    price carries none (it was saved before them)."""
    if not ounce:
        return 0.0
    if terms is None:
        return float(ounce) / TROY_OZ_TO_GRAMS * SAR_USD_PEG * int(karat) / 24.0
    return terms.gram(ounce, karat)


def ounce_for_gram_24(gram_24: float, terms: OfficeTerms | None) -> float:
    """The ounce a 24k gram price was made from -- the office's gram, by *terms*
    (its fees taken off), or by the ounce without them. A price entered by hand
    in riyals is saved as the ounce it stands for."""
    if not gram_24:
        return 0.0
    if terms is None:
        return float(gram_24) / SAR_USD_PEG * TROY_OZ_TO_GRAMS
    kilo = float(gram_24) * 1000.0
    return kilo / (OUNCES_PER_KILO * SAR_USD_PEG) - terms.main_fees_usd - terms.custom_fees_usd


def settings_terms() -> OfficeTerms:
    """The terms the settings hold now (the owner's)."""
    from core.settings import _get_settings_singleton
    settings = _get_settings_singleton(create_if_missing=False)

    def term(name, default):
        value = getattr(settings, name, None) if settings is not None else None
        return float(value) if value is not None else default
    return OfficeTerms(term('office_main_fees_usd', 1.35), term('office_custom_fees_usd', 43.0),
                       term('office_discount_21', 0.75), term('office_discount_18', 1.0))


def terms_of(row) -> OfficeTerms | None:
    """The terms a saved price carries -- None when it was saved before them."""
    if row is None or getattr(row, 'office_custom_fees_usd', None) is None:
        return None
    return OfficeTerms(float(row.office_main_fees_usd or 0.0), float(row.office_custom_fees_usd),
                       float(row.office_discount_21 or 0.0), float(row.office_discount_18 or 0.0))


def stamp(row, terms: OfficeTerms | None = None):
    """A price about to be saved takes the settings' terms (or *terms*)."""
    terms = terms or settings_terms()
    row.office_main_fees_usd = terms.main_fees_usd
    row.office_custom_fees_usd = terms.custom_fees_usd
    row.office_discount_21 = terms.discount_21
    row.office_discount_18 = terms.discount_18
    return row


def row_gram_price(row, karat: int) -> float:
    """SAR a gram of *karat* by a saved price, with its own terms."""
    return gram_price(getattr(row, 'price', None), karat, terms_of(row))


def row_gram_prices(row) -> dict[int, float]:
    return {karat: row_gram_price(row, karat) for karat in KARATS}
