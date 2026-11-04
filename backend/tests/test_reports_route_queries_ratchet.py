"""The reports' route queries only go down, as each report moves to services/reports (REPORTS ت0-3, ADR-083).

The repository's law: routes are thin, queries live in services. On the 2 Nov
tree routes/reports.py held 211 query lines; ت0-1 deleted five unread
reports, ت0-2 moved what was not a report, ت0-3 moved the trial balance, ت2-2 the income statement (and deleted the tree's weight one),
ت4-3 deleted the four old sales reports (the sales analysis answers them),
ت4-4ب the sales-against-purchases trend (the purchases analysis answers it).
Each report moved lowers BASELINE to what is left -- this fails above it, and
fails below it until it is lowered, so the gain is kept.

Run:
    python -m pytest tests/test_reports_route_queries_ratchet.py -v
"""
import pathlib
import re

ROUTES = pathlib.Path(__file__).resolve().parents[1] / 'routes' / 'reports.py'
QUERY = re.compile(r'db\.session\.query\(|\.query\.|\.query\b\(|\.filter\(')
BASELINE = 86


def _count() -> int:
    return sum(1 for line in ROUTES.read_text(encoding='utf-8').splitlines() if QUERY.search(line))


def test_the_reports_route_queries_do_not_grow():
    count = _count()
    assert count <= BASELINE, (f'routes/reports.py has {count} query lines, above {BASELINE}: '
                               'a report reads the books in services/reports, its route only answers it')


def test_the_gain_is_kept():
    count = _count()
    assert count >= BASELINE, f'routes/reports.py is down to {count} query lines: lower BASELINE to {count}'
