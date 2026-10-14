"""NAMES-1: the reports the routes migration broke answer again.

Each failed on a name its module no longer imported (`case`, `Item`, `String`,
`AccountingMapping`), the customer aging on `datetime` made local by dead code
after its return, and the bridge monitor on a column AccountingMapping does not
have (mapping_key -- the role is account_type). tests/test_names_defined.py
keeps the class out; this keeps the routes answering.
"""
import pytest

from app import app as flask_app
from models import db

PERIOD = 'start_date=2026-01-01&end_date=2026-12-31'


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.mark.parametrize('url', [
    f'/api/reports/sales_overview?{PERIOD}',
    f'/api/reports/sales_by_customer?{PERIOD}',
    f'/api/reports/sales_by_item?{PERIOD}',
    f'/api/analytics/summary?{PERIOD}',
    '/api/reports/customer_balances_aging',
    '/api/reports/bridge-balance-monitor',
    f'/api/reports/gold-weight-trial-balance?{PERIOD}',
    '/api/system/reset/info',
])
def test_the_report_answers(app, auth_headers, url):
    resp = flask_app.test_client().get(url, headers=auth_headers)
    assert resp.status_code == 200, (resp.status_code, resp.get_data(as_text=True)[:300])


def test_the_admin_dashboard_values_the_stock(app, auth_headers):
    """inventory_value was valued before the pure grams existed -- always None."""
    from datetime import datetime
    from models import GoldPrice
    db.session.add(GoldPrice(price=2400.0, date=datetime(2026, 10, 14, 9, 0)))
    db.session.flush()
    resp = flask_app.test_client().get('/api/dashboard/admin', headers=auth_headers)
    assert resp.status_code == 200
    body = resp.get_json()
    found = []

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == 'inventory_value':
                    found.append(v)
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(body)
    assert found and all(v is not None for v in found), found
