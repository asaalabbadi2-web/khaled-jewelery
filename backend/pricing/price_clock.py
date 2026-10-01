"""The gold price's clock -- one place (the owner, 2 Oct 2026).

gold_price.date is naive UTC since 28 Jul 2026 (gold_price.save_gold_price;
the store reads it so). Readers compute ages in UTC, cut days at Riyadh's
midnight, and send every time marked UTC ('Z') so no screen guesses a zone.
Saudi Arabia keeps UTC+3 all year. Prices stored before 28 Jul are Riyadh wall
clock, and stay as stored (the owner).
"""
from __future__ import annotations

from datetime import date, datetime, timedelta

RIYADH_OFFSET = timedelta(hours=3)


def utc_now() -> datetime:
    return datetime.utcnow()


def to_riyadh(moment_utc: datetime) -> datetime:
    return moment_utc + RIYADH_OFFSET


def riyadh_day_bounds_utc(day: date) -> tuple:
    """[start, end) in UTC of a Riyadh calendar day."""
    start = datetime.combine(day, datetime.min.time()) - RIYADH_OFFSET
    return start, start + timedelta(days=1)


def riyadh_today(now_utc: datetime = None) -> date:
    return to_riyadh(now_utc or utc_now()).date()


def iso_utc(moment_utc: datetime) -> str | None:
    return f'{moment_utc.isoformat()}Z' if moment_utc else None
