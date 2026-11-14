"""A closed month takes no entry (ADR-090, law 9).

The owner (14 Nov 2026): «لا يجوز للفحص الليلي أو إعادة تشغيل المحرك أن ينشئ
قيوداً في شهر مغلق أو يعدّل قيوداً مرحلة. الفحص يكتشف ويبلّغ، أما التصحيح
فيمر عبر إجراء محاسبي مصرح به.»

Two lines, as a posted entry is held (UNPOST-001): the ORM guard
(period_lock_guard.py) refuses readably on every ORM path, and the database
trigger (period_lock_trigger.py) holds against raw SQL. The lock is the last
row of period_lock, a log no row of which changes; services/period_lock.move()
is its one writer, and moving it back is the authorised way into a closed
month.

Run:
    python -m pytest tests/test_period_lock.py -v
"""
import uuid
from datetime import date, datetime

import pytest
import sqlalchemy as sa
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import Account, JournalEntry, JournalEntryLine, Permission, Role, User, db
from period_lock_guard import PeriodClosed
from services.period_lock import PeriodLockRefused, current, move

NOW = datetime(2026, 11, 14, 10, 0)
OCTOBER = date(2026, 10, 31)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _lock(day, reason='test'):
    return move(day, reason=reason, by='tester', now=NOW)


def _account():
    return Account.query.order_by(Account.id).first().id


def _entry(day, *, draft=False, posted=False, line=True):
    je = JournalEntry(entry_number=f'PL-{uuid.uuid4().hex[:10]}', date=datetime.combine(day, datetime.min.time()),
                      description='period lock', is_draft=draft, is_posted=posted)
    db.session.add(je)
    db.session.flush()
    if line:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=_account(), cash_debit=10))
        db.session.flush()
    return je


def _closed(write):
    """Run *write* and flush in a savepoint; the PeriodClosed it raised, or None."""
    sp = db.session.begin_nested()
    try:
        write()
        db.session.flush()
    except PeriodClosed as exc:
        sp.rollback()
        return exc
    sp.rollback()
    return None


def _raw_refused(sql, **params):
    """Raw SQL in a savepoint -- past the ORM guard: True if the database refused it."""
    sp = db.session.begin_nested()
    try:
        db.session.execute(sa.text(sql), params)
        sp.commit()
        return False
    except sa.exc.DBAPIError as exc:
        sp.rollback()
        assert 'period_closed' in str(exc.orig) or 'period_lock is a log' in str(exc.orig), exc
        return True


# ── the ORM guard ──────────────────────────────────────────────────────────────

def test_open_books_take_any_entry():
    assert current() is None
    assert _closed(lambda: _entry(date(2026, 10, 15))) is None


def test_a_new_entry_in_a_closed_month_is_refused_and_says_so():
    _lock(OCTOBER)
    refused = _closed(lambda: _entry(date(2026, 10, 15)))
    assert refused is not None and refused.code == 'period_closed'
    assert '2026-10-15' in refused.message and '2026-10-31' in refused.message
    assert _closed(lambda: _entry(date(2026, 11, 1))) is None          # the first open day


def test_a_draft_in_a_closed_month_is_refused_too():
    _lock(OCTOBER)
    assert _closed(lambda: _entry(date(2026, 10, 15), draft=True)) is not None


def test_an_entry_of_a_closed_month_is_not_changed_nor_deleted():
    je = _entry(date(2026, 10, 15), posted=True)
    _lock(OCTOBER)

    def describe():
        je.description = 'changed'

    def soft_delete():
        je.is_deleted = True

    assert _closed(describe) is not None
    assert _closed(soft_delete) is not None
    assert _closed(lambda: db.session.delete(je)) is not None


def test_an_entry_moves_neither_into_a_closed_month_nor_out_of_one():
    november = _entry(date(2026, 11, 5))
    october = _entry(date(2026, 10, 15))
    _lock(OCTOBER)

    def into():
        november.date = datetime(2026, 10, 30)

    def out_of():
        october.date = datetime(2026, 11, 2)

    assert _closed(into) is not None
    assert _closed(out_of) is not None


def test_a_line_of_a_closed_month_is_not_added_changed_moved_nor_deleted():
    october = _entry(date(2026, 10, 15))
    november = _entry(date(2026, 11, 5))
    line = JournalEntryLine.query.filter_by(journal_entry_id=october.id).one()
    november_line = JournalEntryLine.query.filter_by(journal_entry_id=november.id).one()
    _lock(OCTOBER)

    def add():
        db.session.add(JournalEntryLine(journal_entry_id=october.id, account_id=_account(), cash_credit=10))

    def change():
        line.cash_debit = 20

    def move_in():
        november_line.journal_entry_id = october.id

    assert _closed(add) is not None
    assert _closed(change) is not None
    assert _closed(move_in) is not None
    assert _closed(lambda: db.session.delete(line)) is not None


def test_a_reopened_month_takes_its_correction_and_is_closed_again():
    _lock(OCTOBER)
    assert _closed(lambda: _entry(date(2026, 10, 15))) is not None
    _lock(date(2026, 9, 30), reason='تصحيح قيد أكتوبر')
    assert _closed(lambda: _entry(date(2026, 10, 15))) is None
    _lock(OCTOBER, reason='أُعيد بعد التصحيح')
    assert current() == OCTOBER


# ── the database trigger: raw SQL, past the guard ─────────────────────────────

_RAW_ENTRY = ("INSERT INTO journal_entry (entry_number, date, entry_type, is_draft, is_posted, is_deleted) "
              "VALUES (:n, :d, 'عادي', false, false, false)")


def test_raw_sql_writes_nothing_into_a_closed_month():
    october = _entry(date(2026, 10, 15))
    line_id = JournalEntryLine.query.filter_by(journal_entry_id=october.id).one().id
    _lock(OCTOBER)
    assert _raw_refused(_RAW_ENTRY, n=f'PL-{uuid.uuid4().hex[:10]}', d=datetime(2026, 10, 20))
    assert _raw_refused('UPDATE journal_entry SET description = :x WHERE id = :id', x='raw', id=october.id)
    assert _raw_refused('UPDATE journal_entry_line SET cash_debit = 99 WHERE id = :id', id=line_id)
    assert _raw_refused('DELETE FROM journal_entry_line WHERE id = :id', id=line_id)
    assert _raw_refused('INSERT INTO journal_entry_line (journal_entry_id, account_id, cash_debit, is_deleted) '
                        'VALUES (:je, :acc, 5, false)', je=october.id, acc=_account())
    assert not _raw_refused(_RAW_ENTRY, n=f'PL-{uuid.uuid4().hex[:10]}', d=datetime(2026, 11, 2))


def test_the_lock_is_a_log_no_row_of_which_changes():
    row = _lock(OCTOBER)
    assert _raw_refused('UPDATE period_lock SET closed_through = :d WHERE id = :id', d=date(2026, 9, 30), id=row.id)
    assert _raw_refused('DELETE FROM period_lock WHERE id = :id', id=row.id)


def test_the_lock_opens_only_for_the_system_purge_its_setting_defined_once():
    import period_lock_trigger
    import posted_entry_trigger
    assert period_lock_trigger.PURGE_SETTING is posted_entry_trigger.PURGE_SETTING
    assert f"current_setting('{posted_entry_trigger.PURGE_SETTING}'" in period_lock_trigger.ENTRY_SQL


# ── the laws of a move ────────────────────────────────────────────────────────

@pytest.mark.parametrize('day, reason, code', [
    (OCTOBER, '  ', 'reason_required'),
    (date(2026, 10, 30), 'x', 'not_month_end'),
    (date(2026, 11, 30), 'x', 'not_past'),
])
def test_a_move_is_refused_when(day, reason, code):
    with pytest.raises(PeriodLockRefused) as refused:
        move(day, reason=reason, by='tester', now=NOW)
    assert refused.value.code == code


def test_a_move_that_changes_nothing_is_refused():
    _lock(OCTOBER)
    with pytest.raises(PeriodLockRefused) as refused:
        _lock(OCTOBER)
    assert refused.value.code == 'unchanged'


# ── the routes ────────────────────────────────────────────────────────────────

def _headers_for(*codes):
    g.pop('current_user', None)
    suffix = uuid.uuid4().hex[:8]
    user = User(username=f'pl_{suffix}', full_name='period lock', is_active=True, is_admin=False)
    user.set_password('x')
    db.session.add(user)
    db.session.flush()
    role = Role(name=f'pl_role_{suffix}', name_ar='دور اختبار', is_active=True)
    db.session.add(role)
    db.session.flush()
    for code in codes:
        perm = Permission.query.filter_by(code=code).first()
        if perm is None:
            perm = Permission(code=code, name=code, name_ar=code, category='accounting', is_active=True)
            db.session.add(perm)
            db.session.flush()
        role.permissions.append(perm)
    user.roles.append(role)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def test_only_the_lock_permission_moves_it_and_every_move_is_logged():
    client = flask_app.test_client()
    body = {'closed_through': '2026-10-31', 'reason': 'إقفال أكتوبر'}
    assert client.post('/api/period-lock', headers=_headers_for('journal.view'), json=body).status_code == 403

    owner = _headers_for('journal.view', 'accounting.period_lock')
    g.pop('current_user', None)
    moved = client.post('/api/period-lock', headers=owner, json=body)
    assert moved.status_code == 201, moved.get_json()
    g.pop('current_user', None)
    refused = client.post('/api/period-lock', headers=owner, json={'closed_through': '2026-10-30', 'reason': 'x'})
    assert refused.status_code == 400 and refused.get_json()['error'] == 'not_month_end'

    g.pop('current_user', None)
    read = client.get('/api/period-lock', headers=owner).get_json()
    assert read['closed_through'] == '2026-10-31'
    assert read['history'][0]['reason'] == 'إقفال أكتوبر' and read['history'][0]['changed_by'].startswith('pl_')


def test_a_manual_entry_in_a_closed_month_answers_409_period_closed(auth_headers):
    _lock(OCTOBER)
    leaves = [a.id for a in Account.query.filter(~Account.id.in_(
        db.session.query(Account.parent_id).filter(Account.parent_id.isnot(None)))).order_by(Account.id).limit(2)]
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/journal_entries', headers=auth_headers, json={
        'date': '2026-10-20T00:00:00', 'description': 'into October', 'is_draft': True,
        'lines': [{'account_id': leaves[0], 'cash_debit': 100}, {'account_id': leaves[1], 'cash_credit': 100}],
    })
    assert resp.status_code == 409, resp.get_json()
    assert resp.get_json()['error'] == 'period_closed'
