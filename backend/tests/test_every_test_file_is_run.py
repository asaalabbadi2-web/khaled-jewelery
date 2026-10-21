"""Every test file is run by the gate (20 Oct 2026).

`pytest` runs `testpaths` (pytest.ini): tests/ and a list of root files. 42
root test files were in neither -- written, never run by the gate, and 18 of
them had gone red unseen. One of those held the performance race's purchase
points (test_points_metric_integration: a purchase's riyal profit earned
nothing since 6ff6b10b); it read as flaky, but it simply never ran.

The ratchet: a root test file is in testpaths, or in ungated_test_files.json
-- a list that may only shrink, as each file is mended and brought in (under
tests/, behind db_fence, if it touches the database). A new root test file
that is not run fails here.

Run:
    python -m pytest tests/test_every_test_file_is_run.py -v
"""
import configparser
import glob
import json
import os

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UNGATED = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ungated_test_files.json')


def _testpaths() -> set:
    config = configparser.ConfigParser()
    config.read(os.path.join(BACKEND, 'pytest.ini'), encoding='utf-8')
    return set(config['pytest']['testpaths'].split())


def test_every_root_test_file_is_run_or_listed_as_not_yet():
    with open(UNGATED, encoding='utf-8') as fh:
        allowed = set(json.load(fh))
    root = {os.path.basename(p) for p in glob.glob(os.path.join(BACKEND, 'test_*.py'))}
    not_run = root - _testpaths() - allowed
    assert not not_run, f'test files the gate never runs: {sorted(not_run)} -- add them to pytest.ini testpaths'


def test_the_not_yet_list_names_no_file_that_is_run_or_gone():
    with open(UNGATED, encoding='utf-8') as fh:
        allowed = set(json.load(fh))
    root = {os.path.basename(p) for p in glob.glob(os.path.join(BACKEND, 'test_*.py'))}
    assert not (allowed & _testpaths()), 'a file run by the gate is still listed as not yet'
    assert allowed <= root, f'listed files that are gone: {sorted(allowed - root)} -- strike them'


def test_no_gated_test_talks_to_a_live_server():
    """A gated test runs against the app it imports, not a server on a port.

    Three files brought in by TEST-003 release 1 sent requests to
    http://127.0.0.1:8001 -- the developer's own server. On a machine running
    it they passed (and could have written to its database); in CI there is
    none, and the push failed (21 Oct 2026). They asserted nothing. A test
    reaches the app through its test client (`app.test_client()`).
    """
    import re
    live = re.compile(r'https?://(127\.0\.0\.1|localhost|0\.0\.0\.0)[:/]')
    offenders = []
    for path in sorted(glob.glob(os.path.join(BACKEND, 'tests', '**', '*.py'), recursive=True)):
        with open(path, encoding='utf-8') as fh:
            source = fh.read()
        if re.search(r'^\s*(import requests|from requests)', source, re.M) and live.search(source) \
                and re.search(r'^def test_', source, re.M):
            offenders.append(os.path.relpath(path, BACKEND))
    assert not offenders, f'tests that call a live local server: {offenders} -- use app.test_client()'
