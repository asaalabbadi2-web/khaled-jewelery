"""The judgement of tools/rehearse_release.py: what turns a rehearsal red.

The machinery (restoring, exporting versions, sweeping) is exercised by running
the tool on a real backup; these tests pin the decisions it makes from what it
observed, so a change to the tool cannot quietly let a bad release through.

Run:
    python -m pytest tests/test_rehearse_release.py -v
"""
import json

from tools.rehearse_probe import body_digest, normalize
from tools.rehearse_release import (compare_sweeps, refused_sweeps, fingerprint_changes, serious_restore_errors,
                                    unstable_routes, verdict)


def _green():
    return {
        'restore_errors': [],
        'baseline_boot': {'ok': True}, 'release_boot': {'ok': True}, 'rollback_boot': {'ok': True},
        'migration': {'returncode': 0},
        'anonymous': {'ok': True, 'guard': True, 'open': []},
        'baseline_guard': True,
        'differential': {'status': [], 'body': [], 'added': [], 'removed': []},
        'rollback': {'status': [], 'body': [], 'added': [], 'removed': []},
        'nights': [{'n': 1, 'ok': True, 'changed': []}, {'n': 2, 'ok': True, 'changed': []}],
    }


class TestVerdict:

    def test_a_clean_rehearsal_is_green(self):
        assert verdict(_green()) == []

    def test_a_status_change_is_red_unless_accepted_by_name(self):
        r = _green()
        r['differential']['status'] = [('/api/suppliers', 200, 500)]
        assert any('differential' in x for x in verdict(r))
        assert verdict(r, accepted=['/api/suppliers']) == []

    def test_a_body_change_alone_is_for_review_not_red(self):
        r = _green()
        r['differential']['body'] = ['/api/reports/gold_position']
        assert verdict(r) == []

    def test_the_rollback_must_answer_as_before(self):
        r = _green()
        r['rollback']['status'] = [('/api/invoices', 200, 500)]
        assert any('rollback' in x for x in verdict(r))

    def test_the_first_night_may_write_but_the_second_must_not(self):
        r = _green()
        r['nights'][0]['changed'] = ['safe_box_transaction']
        assert verdict(r) == []
        r['nights'][1]['changed'] = ['safe_box_transaction']
        assert any('not idempotent' in x for x in verdict(r))

    def test_a_failed_night_is_red(self):
        r = _green()
        r['nights'][0]['ok'] = False
        assert any('night 1' in x for x in verdict(r))

    def test_an_open_route_is_red_when_the_release_has_the_guard(self):
        r = _green()
        r['anonymous']['open'] = ['DELETE /api/suppliers/<int:id>']
        assert any('security' in x for x in verdict(r))

    def test_removing_the_guard_is_red(self):
        r = _green()
        r['anonymous'] = {'ok': True, 'guard': False, 'open': ['GET /api/invoices']}
        assert any('removes the deny-by-default guard' in x for x in verdict(r))

    def test_failed_migration_restore_or_boot_are_red(self):
        for key, value in (('migration', {'returncode': 1}), ('restore_errors', ['pg_restore: error: x']),
                           ('release_boot', {'ok': False}), ('rollback_boot', {'ok': False})):
            r = _green()
            r[key] = value
            assert verdict(r), key


class TestObservations:

    def test_transaction_timeout_is_the_only_benign_restore_error(self):
        stderr = ('pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter '
                  '"transaction_timeout"\npg_restore: error: could not create table "x"\n'
                  'pg_restore: warning: errors ignored on restore: 2')
        assert serious_restore_errors(stderr) == ['pg_restore: error: could not create table "x"']

    def test_sweeps_compare_route_by_route(self):
        a = {'routes': {'/api/a': {'status': 200, 'body': 'h1'}, '/api/b': {'status': 200, 'body': 'h2'},
                        '/api/gone': {'status': 200, 'body': 'h'}}}
        b = {'routes': {'/api/a': {'status': 500, 'body': 'x'}, '/api/b': {'status': 200, 'body': 'h3'},
                        '/api/new': {'status': 200, 'body': 'h'}}}
        d = compare_sweeps(a, b)
        assert d == {'status': [('/api/a', 200, 500)], 'unstable_status': [], 'body': ['/api/b'],
                     'added': ['/api/new'], 'removed': ['/api/gone']}

    def test_a_route_that_is_noisy_between_identical_copies_is_set_aside_by_name(self):
        same_code_1 = {'routes': {'/api/clock': {'status': 200, 'body': 't1'}, '/api/x': {'status': 200, 'body': 'h'}}}
        same_code_2 = {'routes': {'/api/clock': {'status': 200, 'body': 't2'}, '/api/x': {'status': 200, 'body': 'h'}}}
        noise = unstable_routes(same_code_1, same_code_2)
        assert noise == {'/api/clock'}
        release = {'routes': {'/api/clock': {'status': 500, 'body': 't3'}, '/api/x': {'status': 200, 'body': 'CHANGED'}}}
        d = compare_sweeps(same_code_2, release, noise)
        assert d['status'] == [] and d['unstable_status'] == [('/api/clock', 200, 500)]
        assert d['body'] == ['/api/x'], 'a real change on a stable route is still reported'

    def test_fingerprints_name_the_tables_that_moved(self):
        assert fingerprint_changes({'voucher': '1:a', 'invoice': '2:b'},
                                   {'voucher': '1:a', 'invoice': '3:c'}) == {'invoice': ('2:b', '3:c')}

    def test_two_answers_that_differ_only_in_when_they_were_made_are_equal(self):
        one = json.dumps({'generated_at': '10:00', 'rows': [{'x': 1, 'timestamp': 't1'}]}).encode()
        two = json.dumps({'generated_at': '10:05', 'rows': [{'x': 1, 'timestamp': 't2'}]}).encode()
        assert body_digest(one) == body_digest(two)
        assert body_digest(one) != body_digest(json.dumps({'rows': [{'x': 2}]}).encode())
        assert normalize({'ran_at': 1, 'keep': {'as_of': 2, 'v': 3}}) == {'keep': {'v': 3}}



def test_a_sweep_that_was_not_signed_in_is_named_not_diffed():
    """30 Sep 2026: the tool refreshed session activity in UTC while the baseline
    measured idle time in local time -- the baseline sweep was refused (401) on
    every route, and the report listed 193 'status changes' that compared
    nothing. A sweep refused on most routes is its own reason, by name."""
    signed_out = {'ok': True, 'routes': {f'/api/r{i}': {'status': 401} for i in range(10)}}
    signed_in = {'ok': True, 'routes': {f'/api/r{i}': {'status': 200} for i in range(10)}}
    reasons = refused_sweeps({'baseline sweep': signed_out, 'release sweep': signed_in})
    assert len(reasons) == 1 and 'baseline sweep' in reasons[0] and 'not signed in' in reasons[0]
    assert refused_sweeps({'release sweep': signed_in}) == []


def test_session_activity_is_refreshed_fresh_for_any_clock():
    """Both a local-clock tree and a UTC-clock tree must read the refreshed
    activity as fresh: the later of the two stamps does."""
    import inspect
    import tools.rehearse_release as rr
    assert "greatest(localtimestamp, timezone('utc', now()))" in inspect.getsource(rr._refresh_sessions)
