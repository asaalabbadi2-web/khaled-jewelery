"""A document's entry is never touched alone -- held at commit, for every code path (UNPOST-001 U3).

The owner's rule (1 Oct 2026): an invoice's or a voucher's entry is not
deleted, soft-deleted or unposted except through its document's own operation
(post_invoice_document, unpost_invoice_document, the invoice's edit, delete and
reject). This guard sits on every SQLAlchemy session -- routes, services,
maintenance tools, the scheduler -- and at commit refuses the states only a
lone touch can leave:

  - an invoice's entry whose posted state differs from its invoice's, or that
    is soft-deleted while the invoice stands posted;
  - an invoice's entry deleted while the invoice remains;
  - a voucher's entry deleted, or soft-deleted, while the voucher remains;
  - a voucher whose status disagrees with its entry (V0, owner 1 Oct 2026):
    approved -- its entry stands posted; cancelled -- its entry stands posted
    and a posted reversal stands beside it (a voucher cancelled before it was
    approved never had one, and has none); pending and rejected -- no entry
    linked and none posted. So an approved voucher is cancelled, never
    rejected: rejecting it would hide a movement the books still count;
  - a bulk DELETE of entries, invoices or vouchers, or a bulk UPDATE of their
    posted/deleted state, or of a voucher's status or entry link -- the ORM
    cannot see which rows those touch.

It is a consistency guard, not a place for the operations' logic: it refuses
the illegal state and repairs nothing. The whole transaction is refused
(DocumentEntryTouchedAlone at commit), so nothing half-done stays.

Only what the transaction touched is checked: records inconsistent from before
(2821 and 3123, SETTINGS-001) are left for the stage-4 repair -- which, like
any write, must leave them consistent.

The one exception is system_purge(): the system resets and wipes of
routes/system.py, which delete everything. It also opens the database trigger
(posted_entry_trigger.py). tests/test_posted_entry_immutable.py fails if any
other runtime code calls it.
"""
from contextlib import contextmanager
from contextvars import ContextVar

from sqlalchemy import event, text
from sqlalchemy.orm import Session

from posted_entry_trigger import PURGE_SETTING

_PURGING = ContextVar('yasargold_system_purge', default=None)
_WATCHED = ('is_posted', 'is_deleted', 'is_draft')


# Entries with no document: written by hand. Everything else belongs to an
# invoice, a voucher, a payment, a reservation, payroll, a reconciliation...
MANUAL_REFERENCE_TYPES = ('', 'manual', 'journal_entry')


def refusal_for(entry, action: str):
    """The API's early, readable refusal (409) -- the guard below and the
    trigger hold regardless. None when *action* is allowed on *entry*.
    action: 'delete' (hard or soft) | 'unpost' | 'restore'."""
    ref = (entry.reference_type or '').strip()
    if ref not in MANUAL_REFERENCE_TYPES:
        return ('document_entry',
                f'هذا القيد يتبع مستندًا ({ref} #{entry.reference_id}) ولا يُعدَّل وحده: '
                'تعامل مع المستند نفسه (ترحيله، أو فكّ ترحيله، أو رفضه، أو حذفه).')
    if action == 'delete' and entry.is_posted:
        return ('posted_entry',
                'القيد المرحّل لا يُحذف: صحّحه بقيد عكسي، فيبقى أثره قابلًا للمراجعة.')
    return None


class DocumentEntryTouchedAlone(Exception):
    """A document's entry was changed without its document (UNPOST-001 U3)."""


@contextmanager
def system_purge(session, reason: str):
    """The one exception: a system reset or wipe that deletes entries,
    invoices and vouchers wholesale. Opens this guard and the database trigger
    for the current transaction only (SET LOCAL). Callers are confined to the
    reset functions of routes/system.py by a test."""
    session.execute(text(f"SET LOCAL {PURGE_SETTING} = 'on'"))
    token = _PURGING.set(reason)
    try:
        yield
    finally:
        _PURGING.reset(token)


def _purging():
    return _PURGING.get() is not None


def _pending(session):
    return session.info.setdefault('journal_entry_guard', {
        'entries': set(), 'invoices': set(), 'vouchers': set(), 'deleted_entries': [], 'unlinked': [],
    })


@event.listens_for(Session, 'after_flush')
def _track(session, flush_context):
    from sqlalchemy import inspect as sa_inspect
    from models import Invoice, JournalEntry, Voucher
    if _purging():
        return
    pending = _pending(session)
    for obj in session.new:
        if isinstance(obj, JournalEntry):
            pending['entries'].add(obj.id)
        elif isinstance(obj, Voucher):
            pending['vouchers'].add(obj.id)
    for obj in session.dirty:
        if isinstance(obj, JournalEntry):
            pending['entries'].add(obj.id)
        elif isinstance(obj, Invoice):
            pending['invoices'].add(obj.id)
        elif isinstance(obj, Voucher):
            pending['vouchers'].add(obj.id)
            # A voucher whose entry link is cut: if that entry is then deleted
            # while the voucher remains, it is the same lone touch.
            for old in sa_inspect(obj).attrs.journal_entry_id.history.deleted or ():
                if old:
                    pending['unlinked'].append((obj.id, old))
    for obj in session.deleted:
        if isinstance(obj, JournalEntry):
            pending['deleted_entries'].append((obj.id, obj.reference_type, obj.reference_id))
        elif isinstance(obj, Invoice):
            pending['invoices'].add(obj.id)


@event.listens_for(Session, 'do_orm_execute')
def _no_bulk(orm_execute_state):
    if _purging() or not (orm_execute_state.is_delete or orm_execute_state.is_update):
        return
    from models import Invoice, JournalEntry, Voucher
    mapper = orm_execute_state.bind_mapper
    cls = getattr(mapper, 'class_', None)
    if cls not in (JournalEntry, Invoice, Voucher):
        return
    if orm_execute_state.is_delete:
        raise DocumentEntryTouchedAlone(
            f'bulk delete of {cls.__tablename__} outside a system purge: '
            'delete through the document\'s operation')
    values = getattr(orm_execute_state.statement, '_values', None) or {}
    names = {getattr(k, 'key', getattr(k, 'name', str(k))) for k in values}
    watched = set(_WATCHED) | ({'status', 'journal_entry_id'} if cls is Voucher else set())
    if names & watched:
        raise DocumentEntryTouchedAlone(
            f'bulk update of {cls.__tablename__}.{sorted(names & watched)} outside a system purge')


@event.listens_for(Session, 'before_commit')
def _check(session):
    if _purging():
        session.info.pop('journal_entry_guard', None)
        return
    # before_commit runs before the commit's own flush: flush first, so what
    # this transaction changes has been seen by _track.
    session.flush()
    pending = session.info.get('journal_entry_guard')
    if not pending:
        return
    from models import Invoice, JournalEntry, Voucher, db
    problems = []
    with session.no_autoflush:
        invoice_ids = set(pending['invoices'])
        for je_id in pending['entries']:
            je = session.get(JournalEntry, je_id)
            if je is not None and je.reference_type == 'invoice' and je.reference_id:
                invoice_ids.add(je.reference_id)
        for inv_id in invoice_ids:
            inv = session.get(Invoice, inv_id)
            if inv is None:
                continue
            entries = session.query(JournalEntry).filter_by(reference_type='invoice', reference_id=inv_id).all()
            # A posted entry taken back by a posted reversal no longer counts
            # (stage 4 corrected rejected 2821 and 3123 so, by entries): under
            # an unposted invoice it is withdrawn, not a lone touch. Without
            # this, any later write to those invoices was refused (10 Oct 2026).
            taken_back = {rid for (rid,) in session.query(JournalEntry.reference_id).filter(
                JournalEntry.reference_type == 'journal_entry_reversal',
                JournalEntry.reference_id.in_([je.id for je in entries] or [-1]),
                JournalEntry.is_posted.is_(True),
                db.func.coalesce(JournalEntry.is_deleted, False).is_(False))}
            for je in entries:
                if je.is_posted and not inv.is_posted and je.id in taken_back:
                    continue
                if bool(je.is_posted) != bool(inv.is_posted):
                    problems.append(f'entry {je.id} is {"posted" if je.is_posted else "unposted"} '
                                    f'but invoice {inv_id} is {"posted" if inv.is_posted else "unposted"}')
                elif inv.is_posted and je.is_deleted:
                    problems.append(f'entry {je.id} is deleted but invoice {inv_id} stands posted')
        for je_id, ref_type, ref_id in pending['deleted_entries']:
            if ref_type == 'invoice' and ref_id and session.get(Invoice, ref_id) is not None:
                problems.append(f'entry {je_id} of invoice {ref_id} was deleted while the invoice remains')
            voucher = _voucher_of(session, Voucher, je_id, ref_type, ref_id)
            if voucher is not None:
                problems.append(f'entry {je_id} of voucher {voucher.id} was deleted while the voucher remains')
        deleted_ids = {je_id for je_id, _, _ in pending['deleted_entries']}
        for voucher_id, old_je_id in pending['unlinked']:
            if old_je_id in deleted_ids and session.get(Voucher, voucher_id) is not None:
                problems.append(f'entry {old_je_id} of voucher {voucher_id} was unlinked and deleted '
                                'while the voucher remains')
        for je_id in pending['entries']:
            je = session.get(JournalEntry, je_id)
            if je is not None and je.is_deleted:
                voucher = _voucher_of(session, Voucher, je.id, je.reference_type, je.reference_id)
                if voucher is not None:
                    problems.append(f'entry {je.id} of voucher {voucher.id} was soft-deleted while the voucher remains')
        voucher_ids = set(pending['vouchers'])
        for je_id in pending['entries']:
            je = session.get(JournalEntry, je_id)
            if je is None:
                continue
            voucher_ids |= {v for (v,) in session.query(Voucher.id).filter(Voucher.journal_entry_id == je_id)}
            if je.reference_type in ('voucher', 'voucher_reversal') and je.reference_id:
                voucher_ids.add(je.reference_id)
        for voucher_id in voucher_ids:
            voucher = session.get(Voucher, voucher_id)
            if voucher is not None:
                problems.extend(_voucher_status_problems(session, JournalEntry, voucher))
    session.info.pop('journal_entry_guard', None)
    if problems:
        raise DocumentEntryTouchedAlone(
            'a document\'s entry was changed without its document (UNPOST-001): ' + '; '.join(problems[:5]))


def _voucher_status_problems(session, JournalEntry, voucher):
    """The voucher's status against its entry (V0). Statuses other than the
    four are not judged: this guard invents none."""
    status = voucher.status
    entry = session.get(JournalEntry, voucher.journal_entry_id) if voucher.journal_entry_id else None
    standing = entry is not None and not entry.is_deleted and bool(entry.is_posted)

    def posted(ref_type):
        return session.query(JournalEntry.id).filter(
            JournalEntry.reference_type == ref_type, JournalEntry.reference_id == voucher.id,
            JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False)).first() is not None

    if status == 'approved' and not standing:
        return [f'voucher {voucher.id} is approved but its entry '
                f'{"is missing" if entry is None else "does not stand posted"}']
    if status == 'cancelled':
        if voucher.journal_entry_id and not standing:
            return [f'voucher {voucher.id} is cancelled but its entry does not stand posted']
        if voucher.journal_entry_id and not posted('voucher_reversal'):
            return [f'voucher {voucher.id} is cancelled but no posted reversal stands beside its entry']
        if not voucher.journal_entry_id and posted('voucher'):
            return [f'voucher {voucher.id} is cancelled before approval but a posted entry counts it']
    if status in ('pending', 'rejected') and (voucher.journal_entry_id or posted('voucher')):
        return [f'voucher {voucher.id} is {status} but has an entry'
                + (' -- an approved voucher is cancelled, not rejected' if status == 'rejected' else '')]
    return []


LEGACY_VOUCHER_MESSAGE = ('هذا السند في حالة غير متسقة من قبل — حالته تخالف قيده — فلا يُعتمد ولا يُرفض ولا يُلغى '
                          'من هنا: أيّ عملية عليه تُبقيه مخالفًا. إصلاحه ضمن المرحلة 4 (إصلاح البيانات).')


def voucher_state_problem(voucher):
    """The voucher's standing inconsistency before anything is done to it, or
    None -- for the routes' readable refusal (409). A voucher left inconsistent
    from before V0 (ten on the 30 Sep copy, e.g. RV-2026-01825) would otherwise
    reach this guard at commit and answer a 500."""
    from models import JournalEntry, db
    problems = _voucher_status_problems(db.session, JournalEntry, voucher)
    return problems[0] if problems else None


def _voucher_of(session, Voucher, je_id, ref_type, ref_id):
    v = session.query(Voucher).filter(Voucher.journal_entry_id == je_id).first()
    if v is None and ref_type == 'voucher' and ref_id:
        v = session.get(Voucher, ref_id)
    return v


@event.listens_for(Session, 'after_soft_rollback')
def _forget(session, previous_transaction):
    session.info.pop('journal_entry_guard', None)
