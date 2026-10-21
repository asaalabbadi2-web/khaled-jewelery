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
