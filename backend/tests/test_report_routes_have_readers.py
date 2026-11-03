"""Every route of the reports is read by someone -- a screen, or a tool named here with why (REPORTS ت0-1).

The owner, 4 Nov 2026 («اوافقك» on deleting the dead routes, after checking
no tool and no test reads them). On the 2 Nov tree nine of the reports' thirty
routes had no screen; five had no reader at all (two cash/gold trial balances,
the dual-system income statement and account statement, a dashboard debug)
and went. A route a screen calls is found in frontend/lib by its path; one
read by a tool or a schedule is named below with its reader -- an unread
route fails here rather than staying for no one.

Run:
    python -m pytest tests/test_report_routes_have_readers.py -v
"""
import pathlib

from app import app as flask_app

FRONTEND = pathlib.Path(__file__).resolve().parents[2] / 'frontend' / 'lib'

# Read by no screen, kept for their reader (path -> who reads it, and why).
READ_ELSEWHERE = {
    '/reports/inventory_reconciliation': 'tools/scenario_matrix.py (the release rehearsal)',
    '/reports/bridge-balance-monitor': 'tools/scenario_matrix.py (the release rehearsal)',
    '/reports/gold_acquisition_reconciliation': 'the nightly reconciliation reads its service; '
                                                'tests/test_gold_acquisition_reconciliation.py',
}


def _report_paths():
    paths = set()
    for rule in flask_app.url_map.iter_rules():
        if not rule.endpoint.startswith('reports.'):
            continue
        path = rule.rule[len('/api'):] if rule.rule.startswith('/api/') else rule.rule
        paths.add(path.split('<', 1)[0])                 # a converter's value is the caller's
    return paths


def _frontend_text():
    return '\n'.join(p.read_text(encoding='utf-8') for p in FRONTEND.rglob('*.dart'))


def test_every_report_route_has_a_reader():
    text = _frontend_text()
    unread = sorted(p for p in _report_paths() if p not in READ_ELSEWHERE and p not in text)
    assert unread == [], f'report routes no screen or named tool reads: {unread}'


def test_a_route_named_as_read_elsewhere_still_exists():
    assert set(READ_ELSEWHERE) <= _report_paths(), 'a reader named for a route that is gone'


def test_the_reports_blueprint_holds_only_reports():
    """REPORTS ت0-2: the sales race's settings and the home leaderboard, and the
    manager's dashboard, are their own (routes/sales_race.py, routes/admin_dashboard.py)."""
    strays = sorted({rule.rule for rule in flask_app.url_map.iter_rules() if rule.endpoint.startswith('reports.')
                     and rule.rule.startswith(('/api/sales-race', '/api/home/', '/api/dashboard/'))})
    assert strays == [], f'not reports, in routes/reports.py: {strays}'
