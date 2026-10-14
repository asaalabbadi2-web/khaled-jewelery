"""STOCK-REPORTS-1 witness: three stock reports in the reports centre do not answer.

«حالة المخزون» (/reports/inventory_status), «أصناف منخفضة المخزون» (/reports/low_stock)
and «حركة المخزون» (/reports/inventory_movement) fail with NameError: `Item` is not
imported in routes/reports.py (since the routes migration, 023253327, July 2026) --
on production too. Found walking the stock screens (ITEMS-UI-1, 14 Oct 2026).

Restoring the import is NOT the fix: the reports compute a stock of their own from
invoice lines, a second answer beside the books (ADR-045: the stock is the posted
entry lines on stock safes, one reader -- services/stock_ledger). They are rebuilt on
that reader or retired -- the owner's call (recovery roadmap, STOCK-REPORTS-1). When
they answer, the strict xfail fails the build until this marker goes.
"""
import pytest

from app import app as flask_app
from models import db


@pytest.fixture(scope='module')
def app():
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.mark.parametrize('url', [
    '/api/reports/inventory_status',
    '/api/reports/low_stock',
    '/api/reports/inventory_movement?start_date=2026-01-01&end_date=2026-12-31',
])
@pytest.mark.xfail(strict=True, reason='STOCK-REPORTS-1: the stock reports fail (Item not imported); '
                                       'rebuilt on services/stock_ledger or retired -- the owner decides')
def test_the_stock_reports_answer(app, auth_headers, url):
    resp = flask_app.test_client().get(url, headers=auth_headers)
    assert resp.status_code == 200, resp.status_code
