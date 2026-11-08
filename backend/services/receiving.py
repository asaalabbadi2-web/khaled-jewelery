"""Receiving before the invoice (ADR-087): from which day it works.

Settings.receiving_from, as Settings.gold_cost_from (ADR-042): NULL in 2026 --
a supplier's purchase posts whole, as it always has; the transition writes
2027's first day (services/transition_2027.opening_settings).
"""
from __future__ import annotations

from datetime import date, datetime

RECEIVED = 'received'
INVOICED = 'invoiced'


def receiving_from():
    from models import Settings
    return getattr(Settings.query.first(), 'receiving_from', None)


def receiving_on(day) -> bool:
    """Whether a supplier's purchase dated *day* is received first."""
    start = receiving_from()
    if start is None or day is None:
        return False
    if isinstance(day, datetime):
        day = day.date()
    return isinstance(day, date) and day >= start
