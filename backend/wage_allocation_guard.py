"""No line on the wages' stock (1320) is left not allocated -- refused at commit (ADR-096 ت1; the owner, 19 Nov 2026).

From Settings.wage_pools_from on, every line on 1320 is a category's pool or a
piece's own wage, its allocations its whole (services/wage_ledger). The
system's writers allocate their lines in their own transaction; a line left
as it is -- a hand's entry on 1320, a writer that forgot -- refuses the
commit that would keep it: «بعد تشغيل القانون، هل يُسمح بقيد يدوي على
1320؟» -- «يُرفض».

At commit, not at flush: a line is written first and allocated after, in the
same transaction. The lines a transaction wrote are gathered at each flush;
before its commit they are read back with their allocations. Before
wage_pools_from (2026's books) nothing is read or refused.

Registered by importing it (models.py).
"""
from sqlalchemy import event, func
from sqlalchemy.orm import Session

KEY = 'yasargold.wage_lines_written'
REQUEST_KEY = 'yasargold.wage_not_allocated'


def _mark_the_request(refused):
    from flask import has_request_context, request
    if has_request_context():
        request.environ.setdefault(REQUEST_KEY, refused)


def answered_readably(response, logger=None):
    """A request refused by the guard answers 400 wage_not_allocated with the
    refusal's words, in place of the error the route made of it."""
    from flask import has_request_context, jsonify, request
    if not has_request_context():
        return response
    refused = request.environ.get(REQUEST_KEY)
    if refused is None:
        return response
    if response.status_code >= 400:
        readable = jsonify({'error': refused.code, 'message': refused.message})
        readable.status_code = 400
        return readable
    if logger is not None:
        logger.error('wage_not_allocated swallowed: %s %s answered %s: %s',
                     request.method, request.path, response.status_code, refused.message)
    return response


def check(session, ids) -> None:
    """The lines *ids* on 1320, dated from wage_pools_from: each allocated whole -- or WageAllocationError."""
    from models import JournalEntry, JournalEntryLine, WageAllocation
    from services.wage_ledger import CENT, WageAllocationError, line_riyals, wage_account_id, wage_pools_from
    start = wage_pools_from()
    account = wage_account_id() if start is not None else None
    if not account:
        return
    from datetime import datetime
    lines = (session.query(JournalEntryLine).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(JournalEntryLine.id.in_(list(ids)), JournalEntryLine.account_id == account,
                     JournalEntryLine.is_deleted.is_(False), JournalEntry.is_deleted.is_(False),
                     JournalEntry.date >= datetime.combine(start, datetime.min.time())).all())
    for line in lines:
        riyals = line_riyals(line)
        if abs(riyals) <= CENT:
            continue
        taken = round(float(session.query(func.coalesce(func.sum(WageAllocation.riyals), 0.0))
                            .filter(WageAllocation.journal_entry_line_id == line.id).scalar() or 0.0), 2)
        if abs(riyals - taken) > CENT:
            refused = WageAllocationError(
                f'سطر على مخزون أجور المصنعية ({abs(riyals):,.2f}) غير موزَّع على تصنيف أو قطعة: لا يُكتب '
                'على هذا الحساب إلا من الشراء والبيع والمرتجعات والصهر والتصحيح والجرد، ولا قيد يدوي عليه')
            _mark_the_request(refused)
            raise refused


def register(JournalEntryLine):
    @event.listens_for(Session, 'after_flush')
    def _gather(session, flush_context):
        written = [o.id for o in session.new if isinstance(o, JournalEntryLine) and o.id is not None]
        if written:
            session.info.setdefault(KEY, set()).update(written)

    @event.listens_for(Session, 'before_commit')
    def _before_commit(session):
        if not session.info.get(KEY):
            return
        session.flush()
        ids = session.info.pop(KEY, set())
        if ids:
            check(session, ids)

    @event.listens_for(Session, 'after_rollback')
    def _forget(session):
        session.info.pop(KEY, None)
