"""The print engine (ADR-097 ط2; the owner, 20 Nov 2026) -- on a printer that is not there.

The owner's ten tests before release, here on a fake printer (ط6 repeats
them on the shop's):
 1. a piece registered with the printer off;
 2. the line dropped after the tag was written, before its answer;
 3. a tag read back that is not the value sent;
 4. a failed attempt, then a new one with another generation;
 5. a completed request sent again prints nothing;
 6. two requests at once from two coders;
 7. a reprint, the old tag stopped once the new one is confirmed;
 8. the old tag read in a count is not counted;
 9. the server stopped with an attempt running;
10. the printer stopping while printing, or out of labels.
And: the attempt is in the database before the printer hears of it (law 9).

Run:
    python -m pytest tests/test_print_engine.py -v
"""
import re
import socket
import threading
import uuid
from datetime import date, datetime, timedelta

import pytest

from models import LabelPrinter, PieceTag, PrintAttempt, PrintJob, Settings, db
from services.label_printing import PrinterNotReady, PrintRefused, _Turn, request_print, resolve_attempt, run_job
from services.pieces import active_tag, epc_of, tag_state
from services.printer_link import LinkLost, PrinterUnreachable, ZebraLink, parse_status
from tests.test_piece_tag import _pieces
from tests.test_stock_count import NOW

READY = '\x02030,0,0,0336,000,0,0,0,000,0,0,0\x03\r\n\x02001,0,0,0,1,2,4,0,00000000,1,000\x03\r\n\x020000,0\x03\r\n'
PAPER_OUT = READY.replace('030,0,0,0336', '030,1,0,0336')
HEAD_OPEN = READY.replace('001,0,0,0,1', '001,0,1,0,1')


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield


class Clock:
    def __init__(self):
        self.t = NOW

    def __call__(self):
        self.t += timedelta(seconds=1)
        return self.t


class FakeLink:
    """A printer: its status before and after, and what it answers a label with."""

    def __init__(self, before=READY, answer='ok', after=READY, events=None):
        self.before, self.answer, self.after = before, answer, after
        self.sent, self.asked, self.events = [], 0, events if events is not None else []

    def status(self):
        self.asked += 1
        self.events.append('status')
        reply = self.before if self.asked == 1 else self.after
        if reply is None:
            raise PrinterUnreachable('off')
        return parse_status(reply)

    def send(self, zpl):
        self.events.append('send')
        self.sent.append(zpl)
        epc = re.search(r'\^RFW,H,,,A\^FD([0-9A-F]{24})\^FS', zpl).group(1)
        if self.answer == 'ok':
            return f'EPC={epc}\r\n'
        if self.answer == 'other':
            return 'EPC=4B4A00000000000000999999\r\n'
        if self.answer == 'empty':
            return 'EPC=\r\n'
        if self.answer == 'silent':
            return ''
        if self.answer == 'lost':
            raise LinkLost('dropped')
        if self.answer == 'off':
            raise PrinterUnreachable('off')
        raise AssertionError(self.answer)


def _printer(name=None):
    p = LabelPrinter(name=name or f'طابعة {uuid.uuid4().hex[:6]}', host='192.0.2.10', created_at=NOW,
                     created_by='t')
    db.session.add(p)
    db.session.flush()
    return p


def _job(piece, printer, **kw):
    return request_print(piece, request_key=kw.pop('key', uuid.uuid4().hex), by='t', now=NOW, printer=printer, **kw)


def _run(job, link, clock=None, wait=1.0):
    return run_job(job, by='t', clock=clock or Clock(), commit=db.session.commit, link=link, wait=wait,
                   sleep=lambda s: None)


def _attempts(job):
    return PrintAttempt.query.filter_by(job_id=job.id).order_by(PrintAttempt.id).all()


# ── the request ──────────────────────────────────────────────────────────────

def test_one_request_key_one_job_and_one_open_job_a_piece():
    a, b = _pieces(10.0, 12.0)
    printer = _printer()
    job = _job(a, printer, key='k-1')
    assert _job(a, printer, key='k-1').id == job.id, 'the same request: the same job'
    with pytest.raises(PrintRefused) as other:
        _job(b, printer, key='k-1')
    assert other.value.code == 'request_key_reused'
    with pytest.raises(PrintRefused) as open_one:
        _job(a, printer)
    assert open_one.value.code == 'job_open'


def test_a_reprint_needs_its_reason_and_a_first_print_no_label():
    [piece] = _pieces(10.0)
    printer = _printer()
    _run(_job(piece, printer), FakeLink())
    with pytest.raises(PrintRefused) as again:
        _job(piece, printer)
    assert again.value.code == 'piece_has_label'
    with pytest.raises(PrintRefused) as bare:
        _job(piece, printer, kind='reprint', reason='  ')
    assert bare.value.code == 'reprint_reason_required'


# ── a run ────────────────────────────────────────────────────────────────────

def test_printed_written_read_and_matching_the_tag_is_the_pieces():
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    link = FakeLink()
    _run(job, link)
    [attempt] = _attempts(job)
    assert job.status == 'completed'
    assert (attempt.generation, attempt.epc) == (1, epc_of(piece.item_code, 1)), 'generation 1: 0 is the old labels\''
    assert (attempt.printed, attempt.written, attempt.verified) == (True, True, True)
    tag = active_tag(piece)
    assert (tag.value, tag.generation, tag.attempt_id) == (attempt.epc, 1, attempt.id)
    assert f'^FD{attempt.epc}^FS' in link.sent[0], 'the attempt\'s value written'


def test_the_attempt_is_in_the_database_before_the_printer_hears_of_it():
    """Law 9: its commit comes before its label is sent -- the printer's status may be asked before."""
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    events = []
    link = FakeLink(events=events)

    def commit():
        events.append(('commit', [a.generation for a in _attempts(job)]))
        db.session.commit()
    run_job(job, by='t', clock=Clock(), commit=commit, link=link, wait=1.0)
    assert ('commit', [1]) in events[:events.index('send')], 'committed with its generation before its label'


def test_1_registered_with_the_printer_off():
    """Asked first, not answering: no attempt, no generation -- the job waits, the piece kept."""
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    with pytest.raises(PrinterNotReady) as off:
        _run(job, FakeLink(before=None))
    assert off.value.code == 'unreachable' and 'لا تردّ' in off.value.message
    assert (job.status, _attempts(job)) == ('pending', []), 'nothing could be printed: nothing spent'
    assert db.session.get(type(piece), piece.id) is not None and active_tag(piece) is None, 'the piece kept, no tag'


def test_pressed_again_and_again_with_the_cable_out_spends_no_generation():
    """ط6 on the owner's printer: nine presses on «إعادة المحاولة», nine generations spent. Not now."""
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    for _ in range(9):
        with pytest.raises(PrinterNotReady):
            _run(job, FakeLink(before=None))
    assert _attempts(job) == []
    _run(job, FakeLink())
    assert [a.generation for a in _attempts(job)] == [1], 'the first label the first generation'


def test_2_the_line_dropped_after_the_tag_was_written():
    """Unknown, not failed: no new attempt until it is settled -- by the reader, its own value, no new generation."""
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    _run(job, FakeLink(answer='lost'))
    [attempt] = _attempts(job)
    assert (job.status, attempt.error_code, attempt.finished_at) == ('needs_attention', 'link_lost', None)
    with pytest.raises(PrintRefused) as unsettled:
        _run(job, FakeLink())
    assert unsettled.value.code == 'attempt_unresolved', 'no new attempt over an unknown one'
    with pytest.raises(PrintRefused) as other:
        resolve_attempt(attempt, read_value=epc_of(piece.item_code, 7), by='t', clock=Clock(),
                        commit=db.session.commit)
    assert other.value.code == 'read_other_tag'
    resolve_attempt(attempt, read_value=attempt.epc.lower(), by='t', clock=Clock(), commit=db.session.commit)
    assert (job.status, attempt.resolution, len(_attempts(job))) == ('completed', 'reader', 1)
    assert active_tag(piece).value == attempt.epc, 'its own value, no new generation'


def test_2b_settled_as_no_label_then_a_new_generation():
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    _run(job, FakeLink(answer='silent'))
    [first] = _attempts(job)
    assert (job.status, first.error_code) == ('needs_attention', 'no_answer')
    resolve_attempt(first, no_label=True, by='t', clock=Clock(), commit=db.session.commit)
    assert (job.status, first.resolution) == ('failed', 'no_label')
    _run(job, FakeLink())
    assert [a.generation for a in _attempts(job)] == [1, 2] and active_tag(piece).generation == 2


def test_3_a_tag_read_back_not_the_value_sent():
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    _run(job, FakeLink(answer='other'))
    [attempt] = _attempts(job)
    assert (job.status, attempt.error_code, attempt.written, attempt.verified) == ('failed', 'mismatch', True, False)
    assert active_tag(piece) is None


def test_4_a_failed_attempt_then_a_new_generation():
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    _run(job, FakeLink(answer='empty'))
    assert (job.status, _attempts(job)[0].error_code) == ('failed', 'not_written'), 'answered empty: certain'
    _run(job, FakeLink())
    first, second = _attempts(job)
    assert (first.generation, second.generation) == (1, 2) and job.status == 'completed'
    assert tag_state(first.epc)['state'] == 'unconfirmed', 'its label, if any, is never the piece\'s'


def test_5_a_completed_request_sent_again_prints_nothing():
    [piece] = _pieces(10.0)
    printer = _printer()
    job = _job(piece, printer, key='once')
    _run(job, FakeLink())
    again = FakeLink()
    same = _job(piece, printer, key='once')
    _run(same, again)
    assert same.id == job.id and again.sent == [] and again.asked == 0 and len(_attempts(job)) == 1


def test_6_two_at_once_on_one_printer_one_waits_another_printer_does_not():
    a, b = _pieces(10.0, 12.0)
    one, two = _printer(), _printer()
    busy = _Turn(one.id, wait=0.0)
    assert busy.__enter__() is True                       # another coder's attempt on the printer
    try:
        waiting = _job(a, one)
        link = FakeLink()
        _run(waiting, link, wait=0.0)
        assert (waiting.status, link.sent, _attempts(waiting)) == ('pending', [], []), 'waits: no attempt yet'
        elsewhere = _job(b, two)
        _run(elsewhere, FakeLink(), wait=0.0)
        assert elsewhere.status == 'completed', 'a second printer is not held by the first'
    finally:
        busy.__exit__(None, None, None)
    _run(waiting, link, wait=0.0)
    assert waiting.status == 'completed', 'its turn came'


def test_7_a_reprint_stops_the_old_tag_once_the_new_is_confirmed():
    [piece] = _pieces(10.0)
    printer = _printer()
    _run(_job(piece, printer), FakeLink())
    old = active_tag(piece)
    reprint = _job(piece, printer, kind='reprint', reason='تلفت البطاقة')
    _run(reprint, FakeLink(answer='other'))
    assert active_tag(piece).id == old.id, 'a failed reprint leaves the old one standing'
    _run(reprint, FakeLink())
    new = active_tag(piece)
    db.session.refresh(old)
    assert new.generation == 3 and old.stopped_at is not None
    assert old.stop_reason == 'استُبدلت بالجيل 0003: تلفت البطاقة'


def test_8_the_old_tag_read_in_a_count_is_not_counted():
    [piece] = _pieces(10.0)
    printer = _printer()
    _run(_job(piece, printer), FakeLink())
    old = active_tag(piece).value
    _run(_job(piece, printer, kind='reprint', reason='تلفت'), FakeLink())
    state = tag_state(old)
    assert (state['state'], state['counted']) == ('stopped', False)
    assert state['message'] == f'رقاقة ملغاة — القطعة {piece.item_code} — الجيل 0001 — لا تُحتسب في الجرد'


def test_9_the_server_stopped_with_an_attempt_running():
    """Its attempt left 'printing' and the lock free (its worker gone): unknown, never sent again."""
    [piece] = _pieces(10.0)
    job = _job(piece, _printer())
    db.session.add(PrintAttempt(job_id=job.id, generation=1, epc=epc_of(piece.item_code, 1), started_by='t',
                                started_at=NOW))
    job.status = 'printing'
    db.session.commit()
    link = FakeLink()
    _run(job, link)
    [attempt] = _attempts(job)
    assert (job.status, attempt.error_code, link.sent) == ('needs_attention', 'stopped_midway', [])


def test_10_out_of_labels_before_and_stopping_while_printing():
    [piece] = _pieces(10.0)
    printer = _printer()
    job = _job(piece, printer)
    link = FakeLink(before=PAPER_OUT)
    with pytest.raises(PrinterNotReady) as out:
        _run(job, link)
    assert (out.value.code, out.value.message) == ('paper_out', 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة')
    assert (job.status, link.sent, _attempts(job)) == ('pending', [], []), 'nothing sent, nothing spent'
    _run(job, FakeLink(after=HEAD_OPEN))
    [first] = _attempts(job)
    assert (job.status, first.error_code, first.verified, first.printed) == \
        ('failed', 'printed_with_error', True, False), 'its tag read, its face not known: not adopted'
    assert active_tag(piece) is None and tag_state(first.epc)['state'] == 'unconfirmed'


# ── the link, on a socket ────────────────────────────────────────────────────

class SocketPrinter:
    """A printer on a local port: ~HS answered READY; a label answered with its own tag value."""

    def __init__(self):
        self.server = socket.socket()
        self.server.bind(('127.0.0.1', 0))
        self.server.listen(4)
        self.port = self.server.getsockname()[1]
        self.received = []
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                data = conn.recv(65536).decode()
                self.received.append(data)
                found = re.search(r'\^RFW,H,,,A\^FD([0-9A-F]{24})\^FS', data)
                conn.sendall((f'EPC={found.group(1)}\r\n' if found else READY).encode())

    def close(self):
        self.server.close()


def test_the_link_reads_a_printers_status_and_tag():
    printer = SocketPrinter()
    try:
        link = ZebraLink('127.0.0.1', printer.port, wait=2.0)
        assert link.status() == {'ready': True, 'stops': [], 'message': None}
        assert link.send('^XA^RFW,H,,,A^FD4B4A00010000000000000125^FS^XZ') == 'EPC=4B4A00010000000000000125\r\n'
    finally:
        printer.close()
    with pytest.raises(PrinterUnreachable):
        ZebraLink('127.0.0.1', printer.port, wait=0.5).status()


def test_a_status_read():
    assert parse_status(PAPER_OUT)['stops'] == ['paper_out']
    assert parse_status(HEAD_OPEN)['message'] == 'غطاء الطابعة مفتوح: أغلقه ثم أعد المحاولة'


def test_the_station_prints_through_the_route(auth_headers):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    [piece] = _pieces(10.0)
    printer = SocketPrinter()
    try:
        _printer().host = '127.0.0.1'
        LabelPrinter.query.order_by(LabelPrinter.id.desc()).first().port = printer.port
        db.session.flush()
        g.pop('current_user', None)
        client = flask_app.test_client()
        r = client.post(f'/api/pieces/{piece.id}/print-jobs', json={'request_key': 'route-1'}, headers=auth_headers)
        assert r.status_code == 200, r.get_data(as_text=True)
        job = r.get_json()['job']
        assert (job['status'], job['last_attempt']['generation'], job['last_attempt']['verified']) == \
            ('completed', 1, True)
        g.pop('current_user', None)
        again = client.post(f'/api/pieces/{piece.id}/print-jobs', json={'request_key': 'route-1'},
                            headers=auth_headers)
        assert again.get_json()['job']['id'] == job['id'] and len(printer.received) == 3, \
            'its key again: the same job, nothing sent (status, label, status)'
        g.pop('current_user', None)
        waiting = client.post(f'/api/pieces/{piece.id}/print-jobs', headers=auth_headers,
                              json={'request_key': 'route-2', 'kind': 'reprint', 'reason': 'تلفت', 'run': False})
        assert waiting.get_json()['job']['status'] == 'pending', '«تسجيل فقط»: saved, not run'
    finally:
        printer.close()


def test_a_completed_job_does_not_wait_for_the_printers_turn():
    [piece] = _pieces(10.0)
    printer = _printer()
    job = _job(piece, printer)
    _run(job, FakeLink())
    waited = []
    busy = _Turn(printer.id, wait=0.0)
    assert busy.__enter__() is True
    try:
        run_job(job, by='t', clock=Clock(), commit=db.session.commit, link=FakeLink(), wait=0.5,
                sleep=waited.append)
    finally:
        busy.__exit__(None, None, None)
    assert waited == [] and job.status == 'completed', 'answered at once: nothing to print'


def test_the_waiting_labels_and_a_printers_status(auth_headers):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    a, b, c = _pieces(10.0, 11.0, 12.0)
    printer = _printer()
    _run(_job(a, printer), FakeLink(answer='other'))                   # failed: another tag read
    _job(b, printer)                                                    # pending: «تسجيل فقط»
    _run(_job(c, printer), FakeLink(answer='lost'))                     # needs attention
    g.pop('current_user', None)
    client = flask_app.test_client()
    body = client.get('/api/print-jobs', headers=auth_headers).get_json()
    assert body['counts'] == {'pending': 1, 'failed': 1, 'needs_attention': 1}
    assert [j['item_code'] for j in body['jobs']] == [a.item_code, b.item_code, c.item_code], 'the oldest first'
    from services.pieces import piece_view
    assert piece_view(a)['label']['status'] == 'failed' and 'غير المطلوبة' in piece_view(a)['label']['message']
    sock = SocketPrinter()
    try:
        printer.host, printer.port = '127.0.0.1', sock.port
        db.session.flush()
        g.pop('current_user', None)
        r = client.get(f'/api/label-printers/{printer.id}/status', headers=auth_headers).get_json()
        assert r['status']['ready'] is True
    finally:
        sock.close()
    g.pop('current_user', None)
    gone = client.get(f'/api/label-printers/{printer.id}/status', headers=auth_headers).get_json()
    assert gone['status'] == {'ready': False, 'stops': ['unreachable'], 'message': gone['status']['message']}
    assert 'لا تردّ' in gone['status']['message']


def test_the_pieces_without_a_label_are_listed(auth_headers):
    """«بلا بطاقة» in «القطع» (ط4): in the stock with no adopted tag -- printed ones out."""
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    a, b = _pieces(10.0, 11.0)
    _run(_job(a, _printer()), FakeLink())
    g.pop('current_user', None)
    listed = flask_app.test_client().get('/api/pieces?untagged=1&state=all&per_page=100',
                                         headers=auth_headers).get_json()
    codes = {p['item_code'] for p in listed['pieces']}
    assert b.item_code in codes and a.item_code not in codes
    row = next(p for p in listed['pieces'] if p['item_code'] == b.item_code)
    assert row['label'] is None and row['tag'] is None


def test_the_route_says_the_printer_is_not_ready_the_job_saved(auth_headers):
    """Saved and waiting: 200 with the job and why -- the station says it, the piece keeps its job."""
    [piece] = _pieces(10.0)
    printer = _printer()
    printer.host, printer.port = '127.0.0.1', 9                     # nothing listens there
    db.session.flush()
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    g.pop('current_user', None)
    r = flask_app.test_client().post(f'/api/pieces/{piece.id}/print-jobs', json={'request_key': 'off-1'},
                                     headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    body = r.get_json()
    assert (body['job']['status'], body['job']['attempts']) == ('pending', 0)
    assert body['printer']['ready'] is False and 'لا تردّ' in body['printer']['message']
