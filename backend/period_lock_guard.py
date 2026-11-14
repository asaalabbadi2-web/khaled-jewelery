"""A closed month takes no entry -- refused readably on every ORM path (ADR-090, law 9).

The database trigger (period_lock_trigger.py) is the last line, against raw
SQL too; this guard refuses the same writes first, at flush, with a message a
person can read (PeriodClosed -> 409 period_closed, app.py). Mapper events on
JournalEntry and JournalEntryLine see every writer -- routes, services, tools,
the schedulers -- not one route.

Refused, when the entry's date is at or before the last closed date: an entry
inserted, changed or deleted; a change moving an entry's date out of a closed
month or into one; a line inserted, changed or deleted on such an entry. A
draft too. An entry whose columns did not change (dirty only by a relationship)
is not judged: nothing of it is written.

Registered by importing it (models.py). It reads the lock through the flush's
own connection, so a move made in the same transaction already counts.
"""
import re
from datetime import datetime

from sqlalchemy import event, inspect as sa_inspect, text
from sqlalchemy.engine import Engine


class PeriodClosed(ValueError):
    """A write into a closed month (ADR-090, law 9)."""
    code = 'period_closed'

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


def closed_through(connection):
    """The last closed date, or None when nothing is closed."""
    row = connection.execute(text('SELECT closed_through FROM period_lock ORDER BY id DESC LIMIT 1')).first()
    return row[0] if row is not None else None


def _day(value):
    if value is None:
        return None
    return value.date() if isinstance(value, datetime) else value


REQUEST_KEY = 'yasargold.period_closed'


def _refuse_if_closed(connection, day, what):
    closed = closed_through(connection)
    if closed is not None and day is not None and day <= closed:
        refused = PeriodClosed(
            f'{what} بتاريخ {day.isoformat()} في فترة مقفلة (مقفلة حتى {closed.isoformat()}): '
            'لا يُكتب فيها ولا يُعدَّل. التصحيح في أول فترة مفتوحة، أو بفتح القفل بإجراء مصرَّح به.')
        _mark_the_request(refused)
        raise refused


_TRIGGER_DATES = re.compile(r'dated (\d{4}-\d{2}-\d{2}).*closed through (\d{4}-\d{2}-\d{2})', re.S)


@event.listens_for(Engine, 'handle_error')
def _the_trigger_refused(context):
    """A write past the mappers -- a bulk delete of lines (an invoice's edit or
    deletion), raw SQL -- is refused by the database trigger, not this guard:
    the request is marked the same, in the same words, so it answers 409 too."""
    text_of = str(getattr(context, 'original_exception', '') or '')
    if 'period_closed:' not in text_of:
        return
    found = _TRIGGER_DATES.search(text_of)
    if found:
        day, closed = found.groups()
        message = (f'قيد بتاريخ {day} في فترة مقفلة (مقفلة حتى {closed}): لا يُكتب فيها ولا يُعدَّل. '
                   'التصحيح في أول فترة مفتوحة، أو بفتح القفل بإجراء مصرَّح به.')
    else:
        message = 'كتابة في فترة مقفلة: التصحيح في أول فترة مفتوحة، أو بفتح القفل بإجراء مصرَّح به.'
    _mark_the_request(PeriodClosed(message))


def _mark_the_request(refused):
    """Many routes catch every exception and answer 500 (or 400 with its
    text): the refusal would hold, but its words be lost. The request is marked
    here, and answered_readably() -- app.py, after every request -- answers it
    409 period_closed whatever the route made of it."""
    from flask import has_request_context, request
    if has_request_context():
        request.environ.setdefault(REQUEST_KEY, refused)


def answered_readably(response, logger=None):
    """The response a request refused by the lock answers: 409 period_closed
    with the refusal's words, in place of the error the route made of it. A
    route that swallowed it and answered success is logged as an error -- part
    of what it said it wrote was not written -- and its response left as is."""
    from flask import has_request_context, jsonify, request
    if not has_request_context():
        return response
    refused = request.environ.get(REQUEST_KEY)
    if refused is None:
        return response
    if response.status_code >= 400:
        readable = jsonify({'error': refused.code, 'message': refused.message})
        readable.status_code = 409
        return readable
    if logger is not None:
        logger.error('period_closed swallowed: %s %s answered %s although a write was refused: %s',
                     request.method, request.path, response.status_code, refused.message)
    return response


def _columns_changed(target) -> bool:
    state = sa_inspect(target)
    return any(state.attrs[attr.key].history.has_changes() for attr in state.mapper.column_attrs)


def _added(target, key):
    """The value this flush writes to *key*, if it writes one."""
    return [v for v in (sa_inspect(target).attrs[key].history.added or ()) if v is not None]


def _entry_day(connection, entry_id):
    if entry_id is None:
        return None
    row = connection.execute(text('SELECT date FROM journal_entry WHERE id = :id'), {'id': entry_id}).first()
    return _day(row[0]) if row is not None else None


def register(JournalEntry, JournalEntryLine):
    @event.listens_for(JournalEntry, 'before_insert')
    def _entry_insert(mapper, connection, target):
        _refuse_if_closed(connection, _day(target.date), 'قيد')

    @event.listens_for(JournalEntry, 'before_update')
    def _entry_update(mapper, connection, target):
        if not _columns_changed(target):
            return
        # the date it stands at in the database, and the one it is moved to
        for day in [_entry_day(connection, target.id), *map(_day, _added(target, 'date'))]:
            _refuse_if_closed(connection, day, f'القيد {target.entry_number}')

    @event.listens_for(JournalEntry, 'before_delete')
    def _entry_delete(mapper, connection, target):
        _refuse_if_closed(connection, _entry_day(connection, target.id), f'القيد {target.entry_number}')

    @event.listens_for(JournalEntryLine, 'before_insert')
    def _line_insert(mapper, connection, target):
        _refuse_if_closed(connection, _entry_day(connection, target.journal_entry_id), 'سطر قيد')

    @event.listens_for(JournalEntryLine, 'before_update')
    def _line_update(mapper, connection, target):
        if not _columns_changed(target):
            return
        # the entry it stands on in the database, and the one it is moved to
        row = connection.execute(text('SELECT journal_entry_id FROM journal_entry_line WHERE id = :id'),
                                 {'id': target.id}).first()
        for entry_id in [row[0] if row else None, *_added(target, 'journal_entry_id')]:
            _refuse_if_closed(connection, _entry_day(connection, entry_id), 'سطر قيد')

    @event.listens_for(JournalEntryLine, 'before_delete')
    def _line_delete(mapper, connection, target):
        row = connection.execute(text('SELECT journal_entry_id FROM journal_entry_line WHERE id = :id'),
                                 {'id': target.id}).first()
        _refuse_if_closed(connection, _entry_day(connection, row[0] if row else target.journal_entry_id), 'سطر قيد')


__all__ = ['PeriodClosed', 'answered_readably', 'closed_through', 'register']
