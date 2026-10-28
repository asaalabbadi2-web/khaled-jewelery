"""OFFICE-PRICE-1: a sale still waiting, recorded before the office's terms, is measured at the office's price.

Its scrap price was the ounce's; what waits will be closed at the office's
(the owner, 28 Oct 2026). The tool gives it the office's price for its own
ounce, times the ratio it was sold under -- its market price and profit stay.

Run:
    python -m pytest tests/test_repair_waiting_sales_office_price.py -v
"""
import uuid
from datetime import datetime
from types import SimpleNamespace

import pytest

from app import app as flask_app
from models import AuditLog, GoldPrice, Invoice, db
from pricing.office_price import OfficeTerms, gram_price, stamp
from services.weight_position import Lot

DEWAN = OfficeTerms(1.35, 43.0, 0.75, 1.0)
OUNCE = 4066.0


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def world(monkeypatch):
    from pricing.gold_price_service import get_main_karat
    import services.weight_position as wp
    main = int(get_main_karat())
    market = gram_price(OUNCE, main, None)                     # the ounce's, as it was kept
    since = datetime(2041, 3, 10, 9)

    def sale(when):
        inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=when,
                      total=1000.0, total_tax=0.0, is_posted=True, status='paid',
                      profit_weight_price_per_gram=market, scrap_buy_price_at_sale=round(market * 0.99, 4))
        db.session.add(inv)
        db.session.flush()
        return inv

    before, after = sale(datetime(2041, 3, 9)), sale(datetime(2041, 3, 11))
    db.session.add(stamp(GoldPrice(price=OUNCE, date=since), DEWAN))
    db.session.flush()
    waiting = [Lot('بيع', inv.date, 500.0, 1.2, market, inv.id, scrap_price=inv.scrap_buy_price_at_sale)
               for inv in (before, after)]
    monkeypatch.setattr(wp, '_replayed', lambda until: SimpleNamespace(open_lots=waiting))
    monkeypatch.setattr('services.repair.waiting_sales_office_price._office_since', lambda: since)
    monkeypatch.setattr('pricing.office_price.settings_terms', lambda: DEWAN)
    return SimpleNamespace(main=main, market=market, before=before, after=after)


def test_a_waiting_sale_from_before_is_measured_at_the_office(world):
    from services.repair.waiting_sales_office_price import reprice_waiting_sales
    expected = round(gram_price(OUNCE, world.main, DEWAN) * 0.99, 4)

    plan = reprice_waiting_sales(by='test', now=datetime(2041, 3, 12), dry_run=True)
    assert [c['invoice_id'] for c in plan['changed']] == [world.before.id], 'only the sale from before'
    assert plan['changed'][0]['scrap_price_after'] == pytest.approx(expected)
    assert world.before.scrap_buy_price_at_sale == pytest.approx(world.market * 0.99, abs=1e-4), 'a dry run writes nothing'

    reprice_waiting_sales(by='test', now=datetime(2041, 3, 12), dry_run=False)
    assert world.before.scrap_buy_price_at_sale == pytest.approx(expected)
    assert world.before.profit_weight_price_per_gram == pytest.approx(world.market), 'its market price stays'
    assert AuditLog.query.filter_by(action='repair_waiting_sales_office_price').count() >= 1

    again = reprice_waiting_sales(by='test', now=datetime(2041, 3, 12), dry_run=True)
    assert again['changed'] == [], 'once is enough'
