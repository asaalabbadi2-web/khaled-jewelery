"""Every change of the Settings row is recorded with it -- at flush, on every ORM path (ADR-102).

Five places write the row today: the settings routes, the first setup, the
password policy, the VAT policy (sales_vat_enabled follows today's period) and
the sales race. Rather than five writers each remembering to record, the row
records itself: before an UPDATE of Settings is flushed, each column whose
value changed by its type (services/settings_policy.same) is written to
settings_change through the flush's own connection -- the same transaction, so
a save without its record, or a record of a save that did not happen, cannot
be. A raw SQL UPDATE of settings would pass unseen; a test refuses one in the
code (tests/test_settings_change_audit.py).

Who changed it: the request's user; outside a request, the actor set by
`acting_as(...)`, else 'system'. The request may add its reason and source
(set_context). Registered by importing it (models.py).

A key's version is the id of its last change (versions()): PATCH /settings
compares it under the row's lock, so a key moved since it was seen -- even
back to the value it had -- is a conflict.
"""
from __future__ import annotations

import contextlib
import contextvars
import uuid
from datetime import datetime

from sqlalchemy import event, func, inspect as sa_inspect

_ACTOR = contextvars.ContextVar('settings_actor', default=None)


@contextlib.contextmanager
def acting_as(actor: str):
    """Outside a request: who the changes made inside are recorded as (e.g. 'migration:20261125_x')."""
    token = _ACTOR.set(actor)
    try:
        yield
    finally:
        _ACTOR.reset(token)


def set_context(*, reason=None, source=None):
    """The request's reason and source for the changes it saves."""
    from flask import g, has_request_context
    if has_request_context():
        g.settings_change_reason = (str(reason).strip() or None) if reason is not None else None
        if source is not None:
            g.settings_change_source = source


def _who():
    from flask import g, has_request_context, request
    actor = _ACTOR.get()
    if actor:
        return actor, ('migration' if actor.startswith('migration:') else 'system'), None, {}, None, None
    if has_request_context():
        user = getattr(g, 'current_user', None)
        name = getattr(user, 'username', None)
        if not getattr(g, 'settings_change_request_id', None):
            g.settings_change_request_id = uuid.uuid4().hex
        source = dict(getattr(g, 'settings_change_source', None) or {})
        source.setdefault('ip', request.remote_addr)
        source.setdefault('user_agent', (request.headers.get('User-Agent') or '')[:300])
        label = request.headers.get('X-Device-Label')
        if label:
            source.setdefault('device', label[:120])
        return (name or 'system', 'user' if name else 'system', getattr(user, 'id', None), source,
                getattr(g, 'settings_change_reason', None), g.settings_change_request_id)
    return 'system', 'system', None, {}, None, None


def _changes(target) -> list:
    from services.settings_policy import NOT_RECORDED, same
    state = sa_inspect(target)
    out = []
    for attr in state.mapper.column_attrs:
        key = attr.key
        if key in NOT_RECORDED:
            continue
        history = state.attrs[key].history
        if not history.added:
            continue
        new = history.added[0]
        old = history.deleted[0] if history.deleted else state.committed_state.get(key)
        if same(key, old, new):
            continue
        out.append((key, old, new))
    return out


def register(settings_cls, change_cls):
    @event.listens_for(settings_cls, 'before_update')
    def _record(mapper, connection, target):
        changes = _changes(target)
        if not changes:
            return
        from services.settings_policy import level, recorded
        actor, actor_type, user_id, source, reason, request_id = _who()
        now = datetime.now()   # clock-guard: record-only -- the record's own time, like created_at (ADR-102)
        rows = [{
            'changed_at': now, 'actor': actor, 'actor_type': actor_type, 'user_id': user_id,
            'source_ip': source.get('ip'), 'user_agent': source.get('user_agent'),
            'device_label': source.get('device'), 'request_id': request_id or uuid.uuid4().hex,
            'key': key, 'level': level(key), 'old_value': recorded(key, old), 'new_value': recorded(key, new),
            'reason': reason,
        } for key, old, new in changes]
        connection.execute(change_cls.__table__.insert(), rows)


def versions(keys=None) -> dict:
    """{key: id of its last change} -- 0 for a key never changed."""
    from models import SettingsChange, db
    q = db.session.query(SettingsChange.key, func.max(SettingsChange.id)).group_by(SettingsChange.key)
    if keys is not None:
        q = q.filter(SettingsChange.key.in_(list(keys)))
    found = {k: int(v) for k, v in q.all()}
    return {k: found.get(k, 0) for k in keys} if keys is not None else found
