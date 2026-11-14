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

Before the lock moves forward, what still waits in the months it closes is
shown (pending): a voucher pending, an entry unposted or a draft, an invoice
unposted and not retracted, a period expense's months not posted -- each would
be refused there once closed. The move is refused while any waits
(pending_in_period), unless the owner accepts them by name (accept_pending),
and what was accepted is kept on the lock's row (ADR-090 phase 6).
"""
from __future__ import annotations

import calendar
from datetime import date, datetime


class PeriodLockRefused(ValueError):
    def __init__(self, code: str, message: str, detail=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


LISTED = 50          # each kind of what waits: its count, and at most this many named

# The entries whose reference_id is their invoice's own id (measured on the copy
# of 12 Nov: every 'invoice_payment_deferred', 2,361 of 2,364 'invoice_payments');
# an 'invoice_payment' or 'invoice_correction' names its payment or correction.
INVOICE_ID_REFERENCES = ('invoice', 'invoice_payments', 'invoice_payment_deferred')


def pending(after: date | None, through: date) -> dict:
    """What still waits in the months after *after* through *through* -- each
    would be refused there once they are closed."""
    import datetime as _dt
    from models import Invoice, JournalEntry, PeriodExpense, Voucher, db
    from services.books_invariants import RETRACTED_INVOICE_STATUSES
    from services.period_expense import months_behind
    hi = _dt.datetime.combine(through, _dt.time.max)
    lo = _dt.datetime.combine(after, _dt.time.max) if after else None

    def dated(q, column):
        q = q.filter(column <= hi)
        return q.filter(column > lo) if lo is not None else q

    vouchers = dated(Voucher.query.filter(Voucher.status == 'pending'), Voucher.date).order_by(Voucher.date)
    # An entry of a retracted invoice waits for nothing: it is never posted
    # and counts nowhere (five on the copy of 12 Nov: four rejected sales'
    # drafts, and the payment of 3123 -- the owner, 14 Nov 2026: «من آثار حذف
    # الفواتير السابق ولا يجب ان ترحل»).
    retracted = db.session.query(Invoice.id).filter(
        db.func.coalesce(Invoice.status, '').in_(list(RETRACTED_INVOICE_STATUSES)))
    entries = dated(JournalEntry.query.filter(
        JournalEntry.is_deleted.is_(False),
        db.or_(JournalEntry.is_posted.is_(False), JournalEntry.is_draft.is_(True)),
        # coalesced: a manual entry has no reference, and NULL in a NOT left it out (three-valued)
        db.not_(db.and_(db.func.coalesce(JournalEntry.reference_type, '').in_(INVOICE_ID_REFERENCES),
                        db.func.coalesce(JournalEntry.reference_id, 0).in_(retracted)))),
        JournalEntry.date).order_by(JournalEntry.date)
    invoices = dated(Invoice.query.filter(
        Invoice.is_posted.is_(False),
        db.func.coalesce(Invoice.status, '').notin_(list(RETRACTED_INVOICE_STATUSES))), Invoice.date
    ).order_by(Invoice.date)
    behind = months_behind(through, expenses=PeriodExpense.query.order_by(PeriodExpense.id).all())
    out = {
        'vouchers': {'count': vouchers.count(), 'items': [
            {'id': v.id, 'number': v.voucher_number, 'date': v.date.date().isoformat()} for v in vouchers.limit(LISTED)]},
        'entries': {'count': entries.count(), 'items': [
            {'id': e.id, 'number': e.entry_number, 'date': e.date.date().isoformat(),
             'draft': bool(e.is_draft)} for e in entries.limit(LISTED)]},
        'invoices': {'count': invoices.count(), 'items': [
            {'id': i.id, 'number': i.invoice_type_id, 'type': i.invoice_type, 'date': i.date.date().isoformat()}
            for i in invoices.limit(LISTED)]},
        'period_expenses': {'count': len(behind), 'items': behind[:LISTED]},
    }
    out['total'] = sum(part['count'] for part in out.values() if isinstance(part, dict))
    return out


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


def move(closed_through: date | None, *, reason: str, by: str, now: datetime, accept_pending: bool = False):
    """Close the books through *closed_through* (None: open them all). Moving
    forward, what waits in the months it closes refuses it unless accepted.
    Flushes; the caller commits."""
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
    was = current()
    if closed_through == was:
        raise PeriodLockRefused('unchanged', 'القفل على هذا التاريخ أصلًا.')
    accepted = None
    if closed_through is not None and (was is None or closed_through > was):
        waiting = pending(was, closed_through)
        if waiting['total']:
            if not accept_pending:
                raise PeriodLockRefused(
                    'pending_in_period',
                    f'في الأشهر التي تُقفل ما ينتظر ({waiting["total"]}): عالجه، أو اقبله صراحةً فيُحفظ مع القفل.',
                    detail=waiting)
            import json
            accepted = json.dumps(waiting, ensure_ascii=False)
    row = PeriodLock(closed_through=closed_through, reason=reason, changed_by=by or 'system', changed_at=now,
                     accepted_pending=accepted)
    db.session.add(row)
    db.session.flush()
    return row
