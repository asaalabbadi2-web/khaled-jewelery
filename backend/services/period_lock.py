"""The period lock: closing a month, and opening it again by an authorised move (ADR-090, law 9).

The one writer of period_lock. A move is a new row -- the date closed through
(or none: all open), why, by whom, when -- and the last row is the lock. The
guard (period_lock_guard.py) and the database trigger (period_lock_trigger.py)
then refuse any write into a closed month, from every path.

The laws of a move:
  - it says why (reason_required);
  - a lock closes whole months: its date is a month's last day (not_month_end);
  - only a month already over is closed (not_past);
  - it changes the lock (unchanged).
Moving the lock back is the authorised way to write into a closed month: it is
recorded like any move, with its reason, and moved forward again after.

The check of what still waits in a month before it is closed is ADR-090 phase 6.
"""
from __future__ import annotations

import calendar
from datetime import date, datetime


class PeriodLockRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _month_end(day: date) -> bool:
    return day.day == calendar.monthrange(day.year, day.month)[1]


def current():
    """The last closed date, or None when nothing is closed."""
    from models import PeriodLock
    last = PeriodLock.query.order_by(PeriodLock.id.desc()).first()
    return last.closed_through if last is not None else None


def history() -> list[dict]:
    from models import PeriodLock
    return [row.to_dict() for row in PeriodLock.query.order_by(PeriodLock.id.desc()).all()]


def move(closed_through: date | None, *, reason: str, by: str, now: datetime):
    """Close the books through *closed_through* (None: open them all). Flushes;
    the caller commits."""
    from models import PeriodLock, db
    reason = (reason or '').strip()
    if not reason:
        raise PeriodLockRefused('reason_required', 'اذكر سبب تحريك القفل: يُحفظ في سجلّه.')
    if closed_through is not None:
        if not _month_end(closed_through):
            raise PeriodLockRefused('not_month_end',
                                    f'القفل يُقفل أشهرًا كاملة: {closed_through.isoformat()} ليس آخر يوم في شهره.')
        if closed_through >= now.date():
            raise PeriodLockRefused('not_past',
                                    f'لا يُقفل إلا شهر انتهى: {closed_through.isoformat()} لم يمضِ بعد.')
    if closed_through == current():
        raise PeriodLockRefused('unchanged', 'القفل على هذا التاريخ أصلًا.')
    row = PeriodLock(closed_through=closed_through, reason=reason, changed_by=by or 'system', changed_at=now)
    db.session.add(row)
    db.session.flush()
    return row
