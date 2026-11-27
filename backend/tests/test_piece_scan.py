"""«الجرد بالمسح» (ADR-085 ت2; the owner, 21 Nov 2026).

- A scan counts one of the shop's stock locations, not an office's deposit.
- Its moment is its start: the location's pieces then are expected, and every
  read is judged by that snapshot -- found, elsewhere (named), out, a stopped
  tag, an attempt never adopted, unknown; a label's printed code is a read.
- What the reader sends is kept as it came, once by its batch's key.
- Complete -- the last 3 presses read nothing new, or the button held 3
  seconds since the last new one (settings, policy) -- is the least before
  finishing; before it, finishing is refused unless said early with a reason.
- At the finish the verdicts are frozen: found, missing (a tagged piece not
  read, complete only), unread (finished early), untagged (no adopted tag:
  never missing), moved (its place changed in the books during the scan).
- No entry, no allocation, no piece's place: the books are as they were.

Run:
    python -m pytest tests/test_piece_scan.py -v
"""
import uuid
from datetime import date, timedelta

import pytest

from models import (JournalEntry, PieceScanEvent, PieceScanExpected, PieceScanRead, Settings, StockLineAllocation,
                    db)
from services.piece_scan import ScanRefused, finish_scan, judge, scan_view, start_scan, take_reads
from services.pieces import epc_of, mount_tag, replace_tag
from tests.test_melting_and_renewal_go_one_way import _safe
from tests.test_piece_transfer import _bangles, _pieces, _sold
from tests.test_stock_count import NOW


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.receiving_from = date(2026, 1, 1)
    settings.scan_quiet_presses, settings.scan_quiet_seconds = 3, 3.0
    db.session.flush()
    yield


@pytest.fixture
def shop():
    """A showroom with three tagged pieces and one untagged, another showroom with one."""
    showroom, branch = _safe('showroom'), _safe('showroom', 'معرض الفرع')
    a, b, c, untagged = _pieces(showroom, _bangles(), 10.0, 11.0, 12.0, 13.0)
    [far] = _pieces(branch, _bangles(), 9.0)
    for piece in (a, b, c, far):
        mount_tag(piece, by='t', now=NOW)
    return {'showroom': showroom, 'branch': branch, 'a': a, 'b': b, 'c': c, 'untagged': untagged, 'far': far}


def _read(scan, *values, press, ms=None, key=None, button=False):
    events = [{'kind': 'read', 'value': v, 'press': press, 'ms': ms if ms is not None else press * 1000}
              for v in values]
    if button:
        events.append({'kind': 'button', 'press': press, 'ms': ms if ms is not None else press * 1000})
    return take_reads(scan.id, batch_key=key or uuid.uuid4().hex, events=events, now=NOW)


def _verdicts(scan):
    return {r['value']: r['verdict'] for r in scan_view(scan)['reads']}


def _tag(piece):
    return epc_of(piece.item_code)


def test_a_scan_counts_a_stock_location_not_an_offices_deposit(shop):
    with pytest.raises(ScanRefused) as refused:
        start_scan(safe_box_id=_safe('deposit').id, kind='check', by='t', now=NOW)
    assert refused.value.code == 'scan_location_invalid'
    with pytest.raises(ScanRefused) as kind:
        start_scan(safe_box_id=shop['showroom'].id, kind='weekly', by='t', now=NOW)
    assert kind.value.code == 'scan_kind_invalid'
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='closing', by='t', now=NOW)
    expected = {e.item_id for e in PieceScanExpected.query.filter_by(scan_id=scan.id)}
    assert expected == {shop['a'].id, shop['b'].id, shop['c'].id, shop['untagged'].id}
    assert scan.places.get(str(shop['far'].id)) == shop['branch'].id, 'every other piece\'s place, at the start'


def test_each_read_is_judged_by_the_snapshot(shop):
    a, far = shop['a'], shop['far']
    _sold(shop['showroom'], shop['c'])                                  # out before the scan
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    replace_tag(shop['b'], reason='تلفت', value=epc_of(shop['b'].item_code, 1), by='t', now=NOW)   # its first stopped
    _read(scan, _tag(a), _tag(far), _tag(shop['c']), epc_of(shop['b'].item_code), shop['b'].item_code,
          '4B4A00000000000000999999', 'E2003412012345678901ABCD', press=1)
    said = _verdicts(scan)
    assert said[_tag(a)] == 'found'
    assert said[_tag(far)] == 'elsewhere'
    assert said[_tag(shop['c'])] == 'out'
    assert said[epc_of(shop['b'].item_code)] == 'stopped'
    assert said[shop['b'].item_code] == 'found', 'its printed code is a read'
    assert said['4B4A00000000000000999999'] == 'unknown' and said['E2003412012345678901ABCD'] == 'unknown'
    words = {r['value']: r['words'] for r in scan_view(scan)['reads']}
    assert 'معرض الفرع' in words[_tag(far)], 'elsewhere: where the books have it'
    assert 'المعتمدة الجيل' in words[epc_of(shop['b'].item_code)]


def test_what_the_reader_sent_is_kept_once_by_its_batch(shop):
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), _tag(shop['a']), press=1, key='batch-1')
    _read(scan, _tag(shop['a']), _tag(shop['a']), press=1, key='batch-1')     # sent again: nothing
    _read(scan, _tag(shop['a']), press=2, key='batch-2')
    assert PieceScanEvent.query.filter_by(scan_id=scan.id).count() == 3, 'every read as it came, repeats too'
    assert PieceScanRead.query.filter_by(scan_id=scan.id).count() == 1, 'each value once'
    [read] = scan_view(scan)['reads']
    assert (read['first_press'], read['presses']) == (1, 2)


def test_complete_is_three_quiet_presses_or_three_seconds_held(shop):
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), press=1)
    _read(scan, _tag(shop['a']), _tag(shop['b']), press=2)               # b new at the second press
    _read(scan, _tag(shop['a']), _tag(shop['b']), press=3)
    _read(scan, _tag(shop['a']), _tag(shop['b']), press=4)
    assert scan_view(scan)['completeness']['complete'] is False, 'two quiet presses'
    with pytest.raises(ScanRefused) as refused:
        finish_scan(scan.id, by='t', now=NOW)
    assert refused.value.code == 'scan_not_complete'
    _read(scan, _tag(shop['a']), _tag(shop['b']), press=5)
    assert scan_view(scan)['completeness']['complete'] is True
    held = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(held, _tag(shop['a']), press=1, ms=100)
    _read(held, press=1, ms=2900, button=True)
    assert scan_view(held)['completeness']['complete'] is False
    _read(held, press=1, ms=3200, button=True)                            # held 3.1 s since the last new
    assert scan_view(held)['completeness']['complete'] is True
    Settings.query.first().scan_quiet_presses = 9                          # policy, not a number in the code
    db.session.flush()
    assert scan_view(scan)['completeness']['complete'] is False, 'three short presses a second apart: no held time'
    waited = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(waited, _tag(shop['a']), press=1, ms=100)
    _read(waited, _tag(shop['a']), press=2, ms=5000)                      # a pause of five seconds, one press
    assert scan_view(waited)['completeness']['complete'] is False, 'a pause between presses is no reading'


def test_every_piece_expected_found_at_once_is_complete(shop):
    """The owner's rehearsal, 23 Nov 2026: «تظهر جميع القطع من أول مسحة وزر إنهاء
    الجرد لا زال غير مفعّل» -- a reader reads a showcase in one press; none
    left to wait for, the count may finish."""
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), _tag(shop['b']), press=1)
    said = scan_view(scan)['completeness']
    assert (said['complete'], said['all_found']) == (False, False), 'two of four: the quiet presses wait'
    _read(scan, _tag(shop['c']), shop['untagged'].item_code, press=1)       # the last, its printed code
    said = scan_view(scan)['completeness']
    assert (said['complete'], said['all_found'], said['quiet_presses']) == (True, True, 0)
    finished = finish_scan(scan.id, by='t', now=NOW)
    assert finished.complete is True


def test_each_piece_read_says_its_weight_and_the_grams_found(shop):
    """The owner's rehearsal, 23 Nov 2026: «عرض لبيانات مثل الوزن الممسوح»."""
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), _tag(shop['far']), press=1)
    view = scan_view(scan)
    read = {r['value']: r for r in view['reads']}[_tag(shop['a'])]
    assert (read['item_code'], read['weight']) == (shop['a'].item_code, round(shop['a'].weight, 3))
    assert read['piece_name'], 'its model, else its category'
    expected = [shop[k] for k in ('a', 'b', 'c', 'untagged')]
    assert view['expected_grams'] == round(sum(p.weight for p in expected), 3)
    assert view['found_grams'] == round(shop['a'].weight, 3), 'a piece elsewhere is not found here'


def test_the_finish_freezes_found_missing_untagged(shop):
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='closing', by='t', now=NOW)
    for press in range(1, 5):
        _read(scan, _tag(shop['a']), _tag(shop['far']), press=press)
    finish_scan(scan.id, by='closer', now=NOW + timedelta(minutes=5))
    view = scan_view(scan)
    by_piece = {p['item_id']: p['verdict'] for p in view['expected_pieces']}
    assert by_piece[shop['a'].id] == 'found'
    assert by_piece[shop['b'].id] == 'missing' and by_piece[shop['c'].id] == 'missing'
    assert by_piece[shop['untagged'].id] == 'untagged', 'no adopted tag to read: not counted missing'
    assert (view['status'], view['complete'], view['finished_by']) == ('finished', True, 'closer')
    assert {r['value']: r['verdict'] for r in view['reads']}[_tag(shop['far'])] == 'elsewhere'
    replace_tag(shop['a'], reason='بعد الجرد', value=epc_of(shop['a'].item_code, 1), by='t', now=NOW)
    assert _verdicts(scan)[_tag(shop['a'])] == 'found', 'frozen: the scan says what was so that day'
    with pytest.raises(ScanRefused) as closed:
        _read(scan, _tag(shop['b']), press=9)
    assert closed.value.code == 'scan_not_open'


def test_finished_early_says_so_and_names_no_piece_missing(shop):
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), press=1)
    with pytest.raises(ScanRefused) as no_reason:
        finish_scan(scan.id, by='t', now=NOW, early=True)
    assert no_reason.value.code == 'scan_early_reason'
    finish_scan(scan.id, by='t', now=NOW, early=True, reason='انقطع الواي فاي')
    view = scan_view(scan)
    assert (view['complete'], view['early_reason']) == (False, 'انقطع الواي فاي')
    by_piece = {p['item_id']: p['verdict'] for p in view['expected_pieces']}
    assert by_piece[shop['b'].id] == 'unread', 'not read in a scan not complete: not «missing»'


def test_one_moment_the_start_and_what_moved_during_the_scan_said_apart(shop):
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='closing', by='t', now=NOW)
    for press in range(1, 5):
        _read(scan, _tag(shop['a']), press=press)
    _sold(shop['showroom'], shop['a'])                                     # read, then sold
    _sold(shop['showroom'], shop['b'])                                     # not read, sold
    _sold(shop['branch'], shop['far'])                                     # elsewhere at the start, then sold
    for press in range(5, 9):                                              # a new value: three quiet presses after it
        _read(scan, _tag(shop['far']), press=press)
    assert _verdicts(scan)[_tag(shop['a'])] == 'found', 'judged by the start: what the coder saw'
    assert _verdicts(scan)[_tag(shop['far'])] == 'elsewhere', 'by the start, not by what came after'
    finish_scan(scan.id, by='t', now=NOW)
    view = scan_view(scan)
    pieces = {p['item_id']: p for p in view['expected_pieces']}
    assert pieces[shop['a'].id]['verdict'] == 'found' and 'أثناء الجرد' in pieces[shop['a'].id]['moved']
    assert pieces[shop['b'].id]['verdict'] == 'moved', 'gone in the books during the scan: not «missing»'
    assert pieces[shop['c'].id]['verdict'] == 'missing'
    far = {r['value']: r for r in view['reads']}[_tag(shop['far'])]
    assert far['verdict'] == 'elsewhere' and 'أثناء الجرد' in far['moved']


def test_a_scan_writes_nothing_in_the_books(shop):
    entries, allocations = JournalEntry.query.count(), StockLineAllocation.query.count()
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='opening', by='t', now=NOW)
    for press in range(1, 5):
        _read(scan, _tag(shop['a']), _tag(shop['far']), press=press)
    finish_scan(scan.id, by='t', now=NOW)
    assert (JournalEntry.query.count(), StockLineAllocation.query.count()) == (entries, allocations)


def test_the_routes_carry_it_and_each_is_guarded(app, auth_headers, shop):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    client = flask_app.test_client()
    for method, url in (('get', '/api/piece-scans/locations'), ('post', '/api/piece-scans'),
                        ('post', '/api/piece-scans/1/reads'), ('post', '/api/piece-scans/1/finish'),
                        ('post', '/api/piece-scans/1/abandon'), ('get', '/api/piece-scans/1'),
                        ('get', '/api/piece-scans'), ('get', '/api/piece-scans/open')):
        g.pop('current_user', None)
        assert getattr(client, method)(url).status_code == 401, url
    from tests.test_count_return import _headers_for
    viewer = _headers_for('inventory.view')                                # sees the log, does not count
    counter = _headers_for('inventory.count')                              # counts, does not see the log
    g.pop('current_user', None)
    assert client.post('/api/piece-scans', headers=viewer,
                       json={'safe_box_id': shop['showroom'].id, 'kind': 'check'}).status_code == 403
    for url in ('/api/piece-scans/locations', '/api/piece-scans/open'):
        g.pop('current_user', None)
        assert client.get(url, headers=viewer).status_code == 403, url
    for url in ('/api/piece-scans', '/api/piece-scans/1'):
        g.pop('current_user', None)
        assert client.get(url, headers=counter).status_code == 403, url
    g.pop('current_user', None)
    r = client.post('/api/piece-scans', headers=auth_headers,
                    json={'safe_box_id': shop['showroom'].id, 'kind': 'check'})
    assert r.status_code == 201, r.get_data(as_text=True)
    scan_id = r.get_json()['scan']['id']
    for press in range(1, 5):
        g.pop('current_user', None)
        r = client.post(f'/api/piece-scans/{scan_id}/reads', headers=auth_headers, json={
            'batch_key': f'k{press}', 'events': [{'kind': 'read', 'value': _tag(shop['a']), 'press': press,
                                                  'ms': press * 1000}]})
        assert r.status_code == 200, r.get_data(as_text=True)
    assert r.get_json()['scan']['completeness']['complete'] is True
    g.pop('current_user', None)
    done = client.post(f'/api/piece-scans/{scan_id}/finish', headers=auth_headers, json={}).get_json()['scan']
    assert (done['status'], done['found'], done['expected']) == ('finished', 1, 4)
    g.pop('current_user', None)
    assert client.get('/api/piece-scans', headers=auth_headers).get_json()['scans'][0]['id'] == scan_id
    g.pop('current_user', None)
    assert scan_id not in [x['id'] for x in client.get('/api/piece-scans/open', headers=counter).get_json()['scans']], \
        'finished: not open; and the counter sees the open ones without the log'


# ── its scope: a section, a category, or every piece (the owner, 21 Nov 2026) ──

@pytest.fixture
def shelves():
    from services.item_sections import create_section, set_category_section
    showroom, branch = _safe('showroom'), _safe('showroom', 'العرض الخارجي')
    bangles18, bangles21, rings = _bangles(), _bangles(), _bangles()
    section = create_section(f'بناجر {uuid.uuid4().hex[:5]}', by='t', now=NOW)
    set_category_section(bangles18, section.id)
    set_category_section(bangles21, section.id)
    b18, = _pieces(showroom, bangles18, 10.0)
    b21, = _pieces(showroom, bangles21, 11.0)
    ring, = _pieces(showroom, rings, 5.0)
    far, = _pieces(branch, bangles21, 9.0)
    far_ring, = _pieces(branch, rings, 4.0)
    for piece in (b18, b21, ring, far, far_ring):
        mount_tag(piece, by='t', now=NOW)
    return {'showroom': showroom, 'section': section, 'bangles21': bangles21, 'b18': b18, 'b21': b21,
            'ring': ring, 'far': far, 'far_ring': far_ring}


def test_a_category_s_scan_expects_its_pieces_and_says_the_rest_other_scope(shelves):
    s = shelves
    scan = start_scan(safe_box_id=s['showroom'].id, kind='check', by='t', now=NOW, category_id=s['bangles21'].id)
    assert {e.item_id for e in PieceScanExpected.query.filter_by(scan_id=scan.id)} == {s['b21'].id}
    for press in range(1, 5):
        _read(scan, _tag(s['b21']), _tag(s['b18']), _tag(s['ring']), _tag(s['far']), _tag(s['far_ring']),
              press=press)
    said = _verdicts(scan)
    assert said[_tag(s['b21'])] == 'found'
    assert said[_tag(s['b18'])] == 'other_scope' and said[_tag(s['ring'])] == 'other_scope', \
        'the location\'s pieces outside the scope: not found, not an alert'
    assert said[_tag(s['far'])] == 'elsewhere', 'of the scope, in another location: said'
    assert said[_tag(s['far_ring'])] == 'other_scope', 'outside the scope wherever it is'
    view = scan_view(scan)
    assert (view['found'], view['alerts'], view['scope_words']) == (1, 1, s['bangles21'].name)
    finish_scan(scan.id, by='t', now=NOW)
    assert {p['item_id']: p['verdict'] for p in scan_view(scan)['expected_pieces']} == {s['b21'].id: 'found'}


def test_a_section_s_scan_is_every_karat_of_it(shelves):
    s = shelves
    scan = start_scan(safe_box_id=s['showroom'].id, kind='closing', by='t', now=NOW, section_id=s['section'].id)
    assert {e.item_id for e in PieceScanExpected.query.filter_by(scan_id=scan.id)} == {s['b18'].id, s['b21'].id}
    for press in range(1, 5):
        _read(scan, _tag(s['b21']), _tag(s['ring']), press=press)
    finish_scan(scan.id, by='t', now=NOW)
    view = scan_view(scan)
    by_piece = {p['item_id']: p['verdict'] for p in view['expected_pieces']}
    assert by_piece == {s['b18'].id: 'missing', s['b21'].id: 'found'}, 'the ring is no part of it: never missing'
    assert view['scope_words'] == f'قسم {s["section"].name}'


def test_one_scope_at_most_and_each_one_that_is(shelves):
    s = shelves
    with pytest.raises(ScanRefused) as both:
        start_scan(safe_box_id=s['showroom'].id, kind='check', by='t', now=NOW, section_id=s['section'].id,
                   category_id=s['bangles21'].id)
    assert both.value.code == 'scan_scope_one'
    with pytest.raises(ScanRefused) as none:
        start_scan(safe_box_id=s['showroom'].id, kind='check', by='t', now=NOW, category_id=999999)
    assert none.value.code == 'scan_category_not_found'
    every = start_scan(safe_box_id=s['showroom'].id, kind='check', by='t', now=NOW)
    assert PieceScanExpected.query.filter_by(scan_id=every.id).count() == 3, 'no scope: every piece in the location'


# ── an attempt settled from the reader (ج2; ADR-097 law 10) ──

def _unsettled(piece):
    from tests.test_print_engine import FakeLink, _attempts, _job, _printer, _run
    job = _job(piece, _printer())
    _run(job, FakeLink(answer='lost'))
    [attempt] = _attempts(job)
    assert job.status == 'needs_attention'
    return job, attempt


def test_an_unsettled_attempt_read_in_a_scan_is_settled_by_that_value(shop):
    from services.piece_scan import settle_read
    from services.pieces import active_tag
    piece = shop['untagged']
    job, attempt = _unsettled(piece)
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, attempt.epc, _tag(shop['a']), press=1)
    read = {r['value']: r for r in scan_view(scan)['reads']}[attempt.epc]
    assert (read['verdict'], read['unsettled'], read['attempt_id']) == ('unconfirmed', True, attempt.id)
    with pytest.raises(ScanRefused) as not_one:
        settle_read(scan.id, {r['value']: r for r in scan_view(scan)['reads']}[_tag(shop['a'])]['id'],
                    by='t', clock=lambda: NOW, commit=db.session.flush)
    assert not_one.value.code == 'scan_read_not_unsettled', 'an adopted tag is not an attempt to settle'
    settle_read(scan.id, read['id'], by='reader1', clock=lambda: NOW, commit=db.session.flush)
    assert (job.status, attempt.resolution, attempt.resolved_by) == ('completed', 'reader', 'reader1')
    assert active_tag(piece).value == attempt.epc, 'its own value, its own generation'
    after = {r['value']: r for r in scan_view(scan)['reads']}[attempt.epc]
    assert (after['verdict'], after['resolved_by']) == ('found', 'reader1'), 'the read\'s verdict follows, in the open scan'


def test_an_attempt_settled_before_is_not_settled_again_from_the_reader(shop):
    from services.label_printing import resolve_attempt
    from services.piece_scan import settle_read
    _, attempt = _unsettled(shop['untagged'])
    resolve_attempt(attempt, destroyed=True, by='coder', clock=lambda: NOW, commit=db.session.flush)
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, attempt.epc, press=1)                                      # said destroyed, still here
    read = scan_view(scan)['reads'][0]
    assert (read['verdict'], read['unsettled']) == ('unconfirmed', False)
    with pytest.raises(ScanRefused) as settled:
        settle_read(scan.id, read['id'], by='t', clock=lambda: NOW, commit=db.session.flush)
    assert settled.value.code == 'scan_read_not_unsettled', 'its statement stands: the label is to be destroyed'


def test_a_finished_scan_is_not_settled_from(shop):
    from services.piece_scan import settle_read
    _, attempt = _unsettled(shop['untagged'])
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, attempt.epc, press=1)
    read_id = scan_view(scan)['reads'][0]['id']
    finish_scan(scan.id, by='t', now=NOW, early=True, reason='تجربة')
    with pytest.raises(ScanRefused) as closed:
        settle_read(scan.id, read_id, by='t', clock=lambda: NOW, commit=db.session.flush)
    assert closed.value.code == 'scan_not_open'


def test_never_an_older_generation_over_a_tag_adopted_since(shop):
    from services.label_printing import PrintRefused, resolve_attempt
    piece = shop['untagged']
    job, attempt = _unsettled(piece)
    mount_tag(piece, value=epc_of(piece.item_code, attempt.generation + 1), by='t', now=NOW)
    with pytest.raises(PrintRefused) as older:
        resolve_attempt(attempt, read_value=attempt.epc, by='t', clock=lambda: NOW, commit=db.session.flush)
    assert older.value.code == 'attempt_older_than_tag'


def test_a_tag_read_says_its_state_with_its_piece(app, auth_headers, shop):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    g.pop('current_user', None)
    body = flask_app.test_client().get(f'/api/pieces/by-tag/{_tag(shop["a"])}', headers=auth_headers).get_json()
    assert (body['piece']['item_code'], body['tag']['state'], body['tag']['generation']) == \
        (shop['a'].item_code, 'active', 0)


def test_settling_from_the_reader_is_its_route_and_its_permission(app, auth_headers, shop):
    from flask import g
    from tests.test_count_return import _headers_for
    from tests.test_wage_treatment_follows_the_setting import flask_app
    _, attempt = _unsettled(shop['untagged'])
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, attempt.epc, press=1)
    read_id = scan_view(scan)['reads'][0]['id']
    db.session.commit()
    client = flask_app.test_client()
    counter = _headers_for('inventory.count')
    g.pop('current_user', None)
    url = f'/api/piece-scans/{scan.id}/reads/{read_id}/settle'
    assert client.post(url, headers=counter).status_code == 403, 'a counter does not settle a print attempt'
    g.pop('current_user', None)
    r = client.post(url, headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    assert r.get_json()['scan']['reads'][0]['verdict'] == 'found'


# The owner, 22 Nov 2026 (the screens seen by a designer's eye): who began and ended a scan is said by
# his name, as everywhere else -- not his login. One not found is said by what was written.
def test_who_is_said_by_his_name(shop):
    from models import User
    db.session.add(User(username='scan_sb', full_name='صالح العبادي', password_hash='x'))
    db.session.flush()
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='scan_sb', now=NOW)
    finish_scan(scan.id, by='nobody_known', now=NOW, early=True, reason='تجربة')
    view = scan_view(scan)
    assert view['started_by_name'] == 'صالح العبادي'
    assert view['finished_by_name'] == 'nobody_known'
    assert view['started_by'] == 'scan_sb', 'the login kept beside it'


# The owner, 22 Nov 2026 (the screens by a designer's eye): a log of daily counts needs its location and
# its period -- today, the last 7 days, this month -- asked of the server, by the server's clock.
def test_the_log_by_location_and_period(shop):
    from datetime import timedelta
    from services.piece_scan import abandon_scan, scans_list
    today = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    abandon_scan(today.id, by='t', now=NOW)
    branch = start_scan(safe_box_id=shop['branch'].id, kind='check', by='t', now=NOW - timedelta(days=3))
    abandon_scan(branch.id, by='t', now=NOW)
    old = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW - timedelta(days=40))
    abandon_scan(old.id, by='t', now=NOW)
    ids = lambda **kw: {s['id'] for s in scans_list(now=NOW, **kw)} & {today.id, branch.id, old.id}
    assert ids() == {today.id, branch.id, old.id}
    assert ids(period='today') == {today.id}
    assert ids(period='week') == {today.id, branch.id}
    assert ids(safe_box_id=shop['showroom'].id) == {today.id, old.id}
    assert ids(safe_box_id=shop['showroom'].id, period='week') == {today.id}
    with pytest.raises(ScanRefused) as refused:
        scans_list(now=NOW, period='decade')
    assert refused.value.code == 'scan_period_invalid'


def test_the_log_route_reads_its_location_and_period(shop, auth_headers):
    from flask import g
    from app import app as flask_app
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)

    def get(query):
        g.pop('current_user', None)
        return flask_app.test_client().get(f'/api/piece-scans{query}', headers=auth_headers)

    mine = get(f'?safe_box_id={shop["showroom"].id}')
    assert mine.status_code == 200 and scan.id in {s['id'] for s in mine.get_json()['scans']}
    other = get(f'?safe_box_id={shop["branch"].id}')
    assert scan.id not in {s['id'] for s in other.get_json()['scans']}
    refused = get('?period=decade')
    assert refused.status_code == 400 and refused.get_json()['error'] == 'scan_period_invalid'



# ── a vitrine of hundreds (the owner, 27 Nov 2026: more than 500 pieces a location) ──────────────────
# Measured on a copy of the 27 Nov backup: every 400 ms batch judged each read alone, twice -- about
# two queries a read -- and answered every read again: 600 pieces 0.4 s and 214 KB a batch.

def _queries(fn):
    from sqlalchemy import event
    count = [0]

    def seen(*_):
        count[0] += 1
    event.listen(db.engine, 'before_cursor_execute', seen)
    try:
        result = fn()
    finally:
        event.remove(db.engine, 'before_cursor_execute', seen)
    return result, count[0]


def test_all_reads_judged_at_once_say_what_each_alone_says(shop):
    from services.piece_scan import judge_all
    job, attempt = _unsettled(shop['untagged'])
    _sold(shop['showroom'], shop['c'])
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    replace_tag(shop['b'], reason='تلفت', value=epc_of(shop['b'].item_code, 1), by='t', now=NOW)
    values = [_tag(shop['a']), _tag(shop['far']), _tag(shop['c']), epc_of(shop['b'].item_code),
              epc_of(shop['b'].item_code, 1), shop['b'].item_code, 'KJ-999999', attempt.epc,
              '4B4A00000000000000999999', 'E2003412012345678901ABCD']
    alone = {v: judge(scan, v) for v in values}
    assert {s['verdict'] for s in alone.values()} >= {'found', 'elsewhere', 'out', 'stopped', 'unconfirmed',
                                                      'unknown'}, 'every kind of read'
    assert judge_all(scan, values) == alone


def test_a_batchs_queries_do_not_grow_with_the_pieces_read():
    showroom = _safe('showroom')
    pieces = _pieces(showroom, _bangles(), *([1.0] * 30))
    for piece in pieces:
        mount_tag(piece, by='t', now=NOW)
    few = start_scan(safe_box_id=showroom.id, kind='check', by='t', now=NOW)
    _read(few, *[_tag(p) for p in pieces[:5]], press=1)
    many = start_scan(safe_box_id=showroom.id, kind='check', by='t', now=NOW + timedelta(seconds=1))
    _read(many, *[_tag(p) for p in pieces], press=1)
    (_, q_few), (_, q_many) = _queries(lambda: scan_view(few)), _queries(lambda: scan_view(many))
    assert q_many <= q_few + 2, f'5 reads {q_few} queries, 30 reads {q_many}: not a query or two a read'
    (_, q_few), (_, q_many) = (_queries(lambda: finish_scan(few.id, by='t', now=NOW, early=True, reason='x')),
                               _queries(lambda: finish_scan(many.id, by='t', now=NOW)))
    assert q_many <= q_few + 8, f'the finish: 5 reads {q_few} queries, 30 reads {q_many}'


def test_a_batchs_answer_carries_every_alert_and_the_reads_since_what_the_screen_holds(shop):
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), _tag(shop['far']), press=1)
    held = max(r['id'] for r in scan_view(scan)['reads'])
    _read(scan, _tag(shop['a']), _tag(shop['b']), press=2)
    view = scan_view(scan, since=held)
    assert {r['value'] for r in view['reads']} == {_tag(shop['far']), _tag(shop['b'])}, \
        'the alert again, the new read -- not the found one the screen already holds'
    assert view['reads_since'] == held
    assert (view['found'], view['alerts'], view['counts']) == (2, 1, {'found': 2, 'elsewhere': 1}), \
        'its figures of every read'
    assert {r['value'] for r in scan_view(scan)['reads']} == {_tag(shop['a']), _tag(shop['far']), _tag(shop['b'])}
    assert 'reads_since' not in scan_view(scan), 'asked without it: every read'


def test_the_reads_route_answers_since_what_the_screen_holds(app, auth_headers, shop):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    client = flask_app.test_client()
    g.pop('current_user', None)
    scan_id = client.post('/api/piece-scans', headers=auth_headers,
                          json={'safe_box_id': shop['showroom'].id, 'kind': 'check'}).get_json()['scan']['id']

    def send(key, since, *values):
        g.pop('current_user', None)
        r = client.post(f'/api/piece-scans/{scan_id}/reads', headers=auth_headers, json={
            'batch_key': key, 'since': since,
            'events': [{'kind': 'read', 'value': v, 'press': 1, 'ms': 1000} for v in values]})
        assert r.status_code == 200, r.get_data(as_text=True)
        return r.get_json()['scan']
    first = send('k1', 0, _tag(shop['a']))
    held = max(r['id'] for r in first['reads'])
    again = send('k2', held, _tag(shop['a']), _tag(shop['b']))
    assert [r['value'] for r in again['reads']] == [_tag(shop['b'])] and again['found'] == 2


# ── what is left to read (the owner, 27 Nov 2026: «اكمل» -- the proposals after the reads kept) ────────

def test_an_open_scan_says_its_expected_pieces_once_with_their_names(shop):
    """Said when the scan is opened or read again -- the screen takes the found away as it reads; a
    batch's answer (since) does not carry them again: a vitrine of thousands."""
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    view = scan_view(scan)
    pieces = {p['item_code']: p for p in view['expected_pieces']}
    assert set(pieces) == {shop[k].item_code for k in ('a', 'b', 'c', 'untagged')}
    a = pieces[shop['a'].item_code]
    assert a['item_id'] == shop['a'].id and a['weight'] == 10.0 and a['piece_name'].startswith('بنجرة نقل'), \
        'what it is, in a word: its model\'s name else its category\'s'
    _read(scan, _tag(shop['a']), press=1)
    assert 'expected_pieces' not in scan_view(scan, since=0), 'a batch\'s answer: not again'


def test_a_finished_scans_missing_pieces_say_what_they_are(shop):
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), press=1, button=True)
    finish_scan(scan.id, by='t', now=NOW, early=True, reason='تجربة')
    pieces = {p['item_code']: p for p in scan_view(scan)['expected_pieces']}
    assert pieces[shop['b'].item_code]['piece_name'].startswith('بنجرة نقل')


# ── the last count of a place, and the grams by karat (the owner, 27 Nov 2026: «اكمل») ───────────────

def test_a_scans_grams_by_karat_expected_found_and_not_found(shop):
    """The server's figures, not the screen's sums: each karat's grams expected, found, not found."""
    shop['c'].karat = '18'
    db.session.flush()
    scan = start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW)
    _read(scan, _tag(shop['a']), _tag(shop['far']), press=1)
    expected = [{'karat': '18', 'expected_grams': 12.0, 'found_grams': 0.0, 'not_found_grams': 12.0},
                {'karat': '21', 'expected_grams': 34.0, 'found_grams': 10.0, 'not_found_grams': 24.0}]
    assert scan_view(scan)['by_karat'] == expected, 'a piece elsewhere is not this place\'s grams'
    assert scan_view(scan, since=0)['by_karat'] == expected, 'in a batch\'s answer too'
    finish_scan(scan.id, by='t', now=NOW, early=True, reason='تجربة')
    assert scan_view(scan)['by_karat'] == expected, 'frozen with the finish'


def test_each_place_says_its_last_count(app, auth_headers, shop):
    """On the start: when the place was last counted, by whom, and what it found -- a finished count
    only; read by whoever counts (inventory.count), as the places are."""
    from flask import g

    from services.piece_scan import abandon_scan
    from tests.test_wage_treatment_follows_the_setting import flask_app

    def last():
        g.pop('current_user', None)
        r = flask_app.test_client().get('/api/piece-scans/locations', headers=auth_headers)
        assert r.status_code == 200, r.get_data(as_text=True)
        return {l['id']: l['last_scan'] for l in r.get_json()['locations']}[shop['showroom'].id]
    assert last() is None, 'never counted'
    done = start_scan(safe_box_id=shop['showroom'].id, kind='closing', by='t', now=NOW)
    _read(done, _tag(shop['a']), _tag(shop['b']), press=1, button=True)
    finish_scan(done.id, by='t', now=NOW + timedelta(minutes=5), early=True, reason='تجربة')
    abandon_scan(start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t',
                            now=NOW + timedelta(hours=1)).id, by='t', now=NOW + timedelta(hours=1))
    start_scan(safe_box_id=shop['showroom'].id, kind='check', by='t', now=NOW + timedelta(hours=2))
    said = last()
    assert said['id'] == done.id, 'the last finished -- not one left, not one open'
    assert (said['kind_words'], said['found'], said['expected'], said['complete'], said['missing']) == \
        ('جرد إغلاق', 2, 4, False, 0), 'finished early: the unread are not missing'
    assert said['finished_at'] == (NOW + timedelta(minutes=5)).isoformat() and said['finished_by_name']
