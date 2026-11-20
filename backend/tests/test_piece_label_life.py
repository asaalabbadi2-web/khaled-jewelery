"""A piece's label has a life (ADR-097 ط1; the owner, 20 Nov 2026).

- The tag value: 4B4A, a generation in four digits, the number in sixteen;
  generation 0 is the value before ADR-097, character for character, kept for
  the labels before it; read back from any generation.
- Each attempt takes the next generation of its piece -- none ever reused.
- A reprint is a request of its own, with a reason; a request key is one job.
- An attempt's tag value is unique for ever.
- A label's history is never erased: no tag, job or attempt deleted, a
  stopped tag and a finished attempt not changed -- the database refuses,
  outside a system purge.
- A value read is active (counted), stopped, an attempt's never confirmed,
  or unknown -- each said.

Run:
    python -m pytest tests/test_piece_label_life.py -v
"""
import uuid
from datetime import date, datetime

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError, InternalError, ProgrammingError

from models import LabelPrinter, PieceTag, PrintAttempt, PrintJob, Settings, db
from services import piece_label
from services.pieces import (PieceRefused, epc_of, epc_parts, mount_tag, next_generation, number_of_epc,
                             replace_tag, tag_state)
from tests.test_piece_tag import _pieces
from tests.test_stock_count import NOW


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield


def _printer():
    p = LabelPrinter(name=f'طابعة {uuid.uuid4().hex[:6]}', host='192.0.2.10', created_at=NOW, created_by='t')
    db.session.add(p)
    db.session.flush()
    return p


def _job(piece, printer, kind='first', reason=None, key=None):
    job = PrintJob(item_id=piece.id, printer_id=printer.id, kind=kind, reason=reason,
                   request_key=key or uuid.uuid4().hex, requested_by='t', requested_at=NOW)
    db.session.add(job)
    db.session.flush()
    return job


def _attempt(job, piece, generation=None, finished=False):
    generation = generation if generation is not None else next_generation(piece)
    a = PrintAttempt(job_id=job.id, generation=generation, epc=epc_of(piece.item_code, generation),
                     started_by='t', started_at=NOW, finished_at=NOW if finished else None)
    db.session.add(a)
    db.session.flush()
    return a


def _refused(statement):
    """The database refuses *statement*; the session left usable."""
    nested = db.session.begin_nested()
    with pytest.raises((IntegrityError, InternalError, ProgrammingError)) as refused:
        db.session.execute(text(statement))
        db.session.flush()
    nested.rollback()
    return str(refused.value)


# ── the value ────────────────────────────────────────────────────────────────

def test_generation_0_is_the_value_before_character_for_character():
    assert epc_of('KJ-000125') == '4B4A00000000000000000125' == epc_of('KJ-000125', 0)
    assert piece_label.epc_of('KJ-000125') == epc_of('KJ-000125')


@pytest.mark.parametrize('number,generation,value', [
    ('KJ-000125', 3, '4B4A00030000000000000125'),
    ('KJ-1234567', 9999, '4B4A99990000000001234567'),
])
def test_the_value_carries_its_generation_and_is_read_back(number, generation, value):
    assert epc_of(number, generation) == value == piece_label.epc_of(number, generation)
    assert epc_parts(value) == (number, generation)
    assert number_of_epc(value) == number, 'the number from any generation'


def test_the_value_has_its_bounds():
    for number, generation in (('KJ-000000', 1), ('KJ-000001', 10000), ('KJ-000001', -1)):
        with pytest.raises(ValueError):
            epc_of(number, generation)
    assert epc_parts('4B4A00010000000000000000') is None, 'no piece numbered 0'
    assert epc_parts('E2801190000000000000ABCD') is None, 'another\'s value'


def test_the_label_writes_the_attempts_value_and_only_its_pieces():
    zpl = piece_label.label_zpl('KJ-000125', epc=epc_of('KJ-000125', 3))
    assert '^FD4B4A00030000000000000125^FS' in zpl
    with pytest.raises(ValueError):
        piece_label.label_zpl('KJ-000125', epc=epc_of('KJ-000126', 3))


# ── the generations ──────────────────────────────────────────────────────────

def test_each_attempt_takes_the_next_generation_none_reused():
    [piece] = _pieces(10.0)
    printer = _printer()
    assert next_generation(piece) == 1, '0 is kept for the labels before'
    first = _job(piece, printer)
    _attempt(first, piece, finished=True)
    _attempt(first, piece, finished=True)
    assert next_generation(piece) == 3
    again = _job(piece, printer, kind='reprint', reason='تلفت')
    assert _attempt(again, piece).generation == 3, 'a reprint goes on from its piece, not its job'


def test_a_generation_past_a_tags_own():
    [piece] = _pieces(10.0)
    mount_tag(piece, value=epc_of(piece.item_code, 7), by='t', now=NOW)
    assert next_generation(piece) == 8


def test_an_attempts_value_is_unique_for_ever():
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    _attempt(job, piece, generation=1, finished=True)
    nested = db.session.begin_nested()
    with pytest.raises(IntegrityError):
        _attempt(job, piece, generation=1)
    nested.rollback()


# ── the jobs ─────────────────────────────────────────────────────────────────

def test_a_reprint_has_its_reason_and_a_key_is_one_job():
    [piece] = _pieces(10.0)
    printer = _printer()
    for reason in (None, '   '):
        nested = db.session.begin_nested()
        with pytest.raises(IntegrityError):
            _job(piece, printer, kind='reprint', reason=reason)
        nested.rollback()
    _job(piece, printer, key='k-1')
    nested = db.session.begin_nested()
    with pytest.raises(IntegrityError):
        _job(piece, printer, key='k-1')
    nested.rollback()


# ── nothing erased ───────────────────────────────────────────────────────────

def test_a_labels_history_is_never_erased():
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    done = _attempt(job, piece, finished=True)
    running = _attempt(job, piece)
    old = mount_tag(piece, value=epc_of(piece.item_code, done.generation), by='t', now=NOW)
    replace_tag(piece, reason='تلفت', value=epc_of(piece.item_code, 9), by='t', now=NOW)
    assert 'not deleted' in _refused(f'DELETE FROM piece_tag WHERE id = {old.id}')
    assert 'stopped' in _refused(f"UPDATE piece_tag SET stop_reason = 'x' WHERE id = {old.id}")
    assert 'not deleted' in _refused(f'DELETE FROM print_job WHERE id = {job.id}')
    assert 'not deleted' in _refused(f'DELETE FROM print_attempt WHERE id = {running.id}')
    assert 'finished' in _refused(f"UPDATE print_attempt SET read_value = 'x' WHERE id = {done.id}")
    db.session.execute(text(f"UPDATE print_attempt SET read_value = 'x' WHERE id = {running.id}"))  # still running
    db.session.execute(text(f"UPDATE print_job SET status = 'completed' WHERE id = {job.id}"))       # its state moves


def test_a_system_purge_may_erase():
    from journal_entry_guard import system_purge
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    attempt = _attempt(job, piece, finished=True)
    with system_purge(db.session, 'test: wipe'):
        db.session.execute(text(f'DELETE FROM print_attempt WHERE id = {attempt.id}'))
        db.session.execute(text(f'DELETE FROM print_job WHERE id = {job.id}'))


# ── a value read ─────────────────────────────────────────────────────────────

def test_a_value_read_is_active_stopped_unconfirmed_or_unknown():
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    _attempt(job, piece, generation=1, finished=True)               # wrote, never confirmed
    two = _attempt(job, piece, generation=2, finished=True)
    mount_tag(piece, value=two.epc, by='t', now=NOW)
    replace_tag(piece, reason='تلفت', value=epc_of(piece.item_code, 3), by='t', now=NOW)
    code = piece.item_code
    assert (tag_state(epc_of(code, 3))['state'], tag_state(epc_of(code, 3))['counted']) == ('active', True)
    stopped = tag_state(two.epc)
    assert (stopped['state'], stopped['counted']) == ('stopped', False)
    assert stopped['message'] == f'رقاقة ملغاة — القطعة {code} — الجيل 0002 — لا تُحتسب في الجرد'
    unconfirmed = tag_state(epc_of(code, 1))
    assert (unconfirmed['state'], unconfirmed['counted']) == ('unconfirmed', False)
    assert unconfirmed['message'] == f'رقاقة من محاولة لم تُعتمد — القطعة {code} — الجيل 0001 — أتلفها'
    assert tag_state('E2801190000000000000ABCD')['state'] == 'unknown'


def test_the_reader_says_what_a_tag_is(auth_headers):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    [piece] = _pieces(10.0)
    mount_tag(piece, value=epc_of(piece.item_code, 1), by='t', now=NOW)
    replace_tag(piece, reason='تلفت', value=epc_of(piece.item_code, 2), by='t', now=NOW)
    g.pop('current_user', None)
    r = flask_app.test_client().get(f'/api/pieces/by-tag/{epc_of(piece.item_code, 1)}', headers=auth_headers)
    assert r.status_code == 404 and r.get_json()['error'] == 'tag_stopped'
    assert 'رقاقة ملغاة' in r.get_json()['message']


def test_the_wipe_takes_the_labels_history_before_the_items():
    """The full wipe (never on production) deletes items: their tags, jobs and attempts first --
    under the purge the history trigger lets it through. Read from its steps, not run: a wipe
    under the test's fence would commit."""
    import inspect
    from routes.system import _reset_full_system_wipe
    steps = [line.split("'")[1] for line in inspect.getsource(_reset_full_system_wipe).splitlines()
             if line.strip().startswith("_step('Delete ")]
    for history in ('Delete PrintAttempt', 'Delete PrintJob', 'Delete PieceTag', 'Delete LabelPrinter'):
        assert history in steps and steps.index(history) < steps.index('Delete Item'), history
    assert steps.index('Delete PrintAttempt') < steps.index('Delete PrintJob') < steps.index('Delete LabelPrinter')
