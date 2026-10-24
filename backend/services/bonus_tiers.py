"""A tiered bonus rule's terms: what it measures, over which period, at which tiers (bonus study م2).

The owner (24 Oct 2026): «كل النقاط بسعر شريحتها» -- 1,600 points against
tiers from 1,000 at 2.5 and from 1,500 at 3 are paid all at 3: 4,800. A tier
pays per unit of the measure or a fixed amount; below the first, nothing.
The rule's cap (min_bonus / max_bonus) applies after.

validate(data) is the one rule for what a rule may say -- the API refuses
by it, the preview reads by it -- and tier_for(tiers, value) the one lookup.
"""
from __future__ import annotations

from services.performance_measures import MEASURES

PERIODS = ('daily', 'weekly', 'monthly')
MEASURE_NAMES = {'points': 'النقاط', 'sales': 'المبيعات', 'sold_weight': 'الوزن المباع', 'count': 'عدد الفواتير'}
PERIOD_NAMES = {'daily': 'يومي', 'weekly': 'أسبوعي', 'monthly': 'شهري'}


class TiersRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _number(value, what):
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise TiersRefused('invalid_tiers', f'{what}: رقم مطلوب')
    if number < 0:
        raise TiersRefused('invalid_tiers', f'{what}: لا يكون سالبًا')
    return number


def validate(data: dict) -> tuple[str, str, list]:
    """(measure, period, tiers) of a tiered rule's body -- or TiersRefused."""
    measure, period, raw = data.get('measure'), data.get('period'), data.get('tiers')
    if measure not in MEASURES:
        raise TiersRefused('invalid_measure', f'المقياس واحد من: {"، ".join(MEASURE_NAMES.values())}')
    if period not in PERIODS:
        raise TiersRefused('invalid_period', f'الفترة واحدة من: {"، ".join(PERIOD_NAMES.values())}')
    if not isinstance(raw, list) or not raw:
        raise TiersRefused('invalid_tiers', 'شريحة واحدة على الأقل')
    tiers, last = [], None
    for n, tier in enumerate(raw, start=1):
        if not isinstance(tier, dict):
            raise TiersRefused('invalid_tiers', f'الشريحة {n}: غير مفهومة')
        start = _number(tier.get('from'), f'الشريحة {n}، «من»')
        if last is not None and start <= last:
            raise TiersRefused('invalid_tiers', f'الشريحة {n}: تبدأ بعد التي قبلها')
        per_unit, amount = tier.get('per_unit'), tier.get('amount')
        if (per_unit is None) == (amount is None):
            raise TiersRefused('invalid_tiers', f'الشريحة {n}: مبلغ لكل وحدة أو مبلغ ثابت، واحد منهما')
        tiers.append({'from': start, 'per_unit': _number(per_unit, f'الشريحة {n}')} if per_unit is not None
                     else {'from': start, 'amount': _number(amount, f'الشريحة {n}')})
        last = start
    return measure, period, tiers


def tier_for(tiers: list, value: float) -> dict | None:
    """The highest tier the value reached; None below the first."""
    reached = [tier for tier in tiers or [] if value >= float(tier['from'])]
    return max(reached, key=lambda tier: float(tier['from'])) if reached else None


def pays(tier: dict | None, value: float) -> float:
    if tier is None:
        return 0.0
    if tier.get('per_unit') is not None:
        return value * float(tier['per_unit'])
    return float(tier.get('amount') or 0.0)
