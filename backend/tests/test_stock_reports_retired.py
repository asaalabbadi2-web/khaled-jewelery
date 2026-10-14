"""STOCK-REPORTS-1: the stock has one answer -- the books (ADR-045).

«حالة المخزون» (/reports/inventory_status), «أصناف منخفضة المخزون» (/reports/low_stock)
and «حركة المخزون» (/reports/inventory_movement) counted a stock of their own from
invoice lines, a second answer beside the books; and none answered since the routes
migration (July 2026: `Item` not imported). Retired by the owner's leave (14 Oct
2026); what they showed lives on the one reader (services/stock_ledger):
balances by location, category and karat in «الجرد الفعلي» and «جرد الأوزان حسب
التصنيف», movements in its «الحركة» tab; per item, value and slow movers belong to
the piece path (ADR-045 C/D). A route that brings one back fails here.
"""
import pytest

from app import app as flask_app
from models import db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.mark.parametrize('path', [
    '/api/reports/inventory_status',
    '/api/reports/low_stock',
    '/api/reports/inventory_movement',
])
def test_no_second_stock_report(app, path):
    rules = {rule.rule for rule in flask_app.url_map.iter_rules()}
    assert path not in rules
