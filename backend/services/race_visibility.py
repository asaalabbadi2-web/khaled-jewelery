"""Who sees what of the race (bonus study م3ي).

The race's settings say, per period, whether its amounts, points, shares and
team summary are for everyone or for the manager alone; a user with the
financial reports sees all. The race card obeyed them and «هدفي» -- inside
the same card -- did not: it said the bonus so far in riyals to whoever was
signed in. One reading of them now, for the race and for the goals.
"""
from __future__ import annotations

import json

#: A goal's period as the race names it.
RACE_PERIOD_OF_GOAL = {'daily': 'today', 'weekly': 'week', 'monthly': 'month'}


def race_config() -> dict:
    """The race's settings as saved (sales_race_settings)."""
    from core.settings import _get_settings_singleton
    try:
        row = _get_settings_singleton(create_if_missing=False)
        raw = getattr(row, 'sales_race_settings', None) if row else None
        parsed = raw if isinstance(raw, dict) else json.loads(raw) if raw else {}
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}


def sees_all(user) -> bool:
    """The manager: an admin, or a user with the financial reports."""
    if user is None:
        return False
    if getattr(user, 'is_admin', False):
        return True
    try:
        return bool(user.has_permission('reports.financial'))
    except Exception:
        return False


def race_visibility(user, period: str, config: dict | None = None) -> dict:
    """{'admin', 'amounts', 'points', 'share', 'team_summary'} for *user* in the
    race's *period* ('today' | 'week' | 'month'): per period first, then the
    flat setting, 'all' by default."""
    config = race_config() if config is None else config
    admin = sees_all(user)
    per_period = (config.get('period_visibility') or {}).get(period, {}) or {}

    def visible(key: str) -> bool:
        if per_period.get(key):
            return per_period[key] == 'all'
        return config.get(f'{key}_visibility', 'all') == 'all'

    return {'admin': admin, **{key: admin or visible(key) for key in ('amounts', 'points', 'share', 'team_summary')}}
