"""What waits is measured against the scrap price of its own sales (ADR-048, decision 5 restated).

The owner (23 Oct 2026): «الأصل أن يكون سعر الأساس هو سعر الكسر أثناء تسجيل
الفاتورة» -- «متوسط سعر ذهب الكسر لوزن الفواتير التي لم تسكر حتى الآن. مثلًا
سجلت فاتورة بيع وزن 1 جرام كان سعر الكسر وقتها 440، فاتورة بعدها 435، وبعدها
430، وكلهن بنفس الوزن 1 جرام: عندها سيكون متوسط سعر التسكير = 435»; then
«ابدأ» on the recommendation: the waiting riyals valued now at the scrap
price now, by the same rule as the sale's -- the market times the buy ratio
-- so the two differ by the price's move alone.

A sale saves its scrap price when it is recorded (frozen: the ratio is a
policy that moved, 0.98 to 0.99). A sale before that has its saved market
price times today's ratio. The closing price is the open sales' scrap
prices weighted by their grams still waiting. The shop's own purchase
average of 7 days is shown beside, as what it paid -- no longer the value.

Run:
    python -m pytest tests/test_closing_price.py -v
"""
import datetime as dt
import uuid

import pytest

from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
from services.weight_position import Lot, closing_price
from tests.test_weight_position import _get, _headers, _post, app  # noqa: F401 (fixture)
from tests.retraction_world import world  # noqa: F401 (fixture)

D = dt.datetime
RATIO = 0.97


@pytest.fixture(autouse=True)
def rollback_after_each(request, db_fence):
    yield


def _main_gram(usd_per_oz):
    from pricing.gold_price_service import get_main_karat
    return usd_per_oz / TROY_OZ_TO_GRAMS * SAR_USD_PEG * get_main_karat() / 24.0


def _market(when, usd_per_oz):
    from models import GoldPrice, db
    db.session.add(GoldPrice(price=usd_per_oz, date=when))
    db.session.flush()


def _ratio(value=RATIO):
    from models import Settings, db
    Settings.query.first().buy_price_ratio = value
    db.session.flush()


def _lot(grams, scrap, cash=None):
    return Lot(f'بيع {grams}', D(2041, 3, 1), cash if cash is not None else grams * scrap, grams,
               scrap_price=scrap)


def test_the_owner_s_example_three_grams_at_440_435_430_close_at_435():
    assert closing_price([_lot(1, 440), _lot(1, 435), _lot(1, 430)]) == pytest.approx(435.0)


def test_it_is_weighted_by_the_grams_still_waiting():
    half_closed = _lot(2, 440)
    half_closed.grams_open = 1.0
    assert closing_price([half_closed, _lot(3, 430)]) == pytest.approx((440 + 3 * 430) / 4)
    assert closing_price([Lot('إيرادات', D(2041, 3, 1), 500, 0.0)]) is None


def test_the_scrap_price_of_a_day_is_its_last_market_price_times_the_ratio(app):
    from services.weight_position import scrap_prices
    _ratio()
    _market(D(2041, 3, 1, 9), 2000.0)
    _market(D(2041, 3, 1, 15), 2100.0)
    _market(D(2041, 3, 3, 10), 2200.0)
    price_on = scrap_prices(dt.date(2041, 3, 5))
    assert price_on(dt.date(2041, 3, 1))[0] == pytest.approx(_main_gram(2100.0) * RATIO)
    assert price_on(dt.date(2041, 3, 2))[0] == pytest.approx(_main_gram(2100.0) * RATIO), 'a quiet day keeps it'
    assert price_on(dt.date(2041, 3, 5))[0] == pytest.approx(_main_gram(2200.0) * RATIO)


def test_a_sale_saves_its_scrap_price_when_it_is_recorded(app, auth_headers, world):
    from models import Invoice, db
    _ratio()
    _market(D(2041, 3, 1, 9), 2000.0)
    sale_id = _post(auth_headers, {
        'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'employee_id': world['holder'].id, 'date': '2041-03-02T10:00:00', 'total': 1000.0, 'total_weight': 2.0,
        'total_tax': 0.0, 'amount_paid': 1000.0, 'payments': [{'payment_method_id': world['pm'].id, 'amount': 1000.0}],
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                   'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]})
    inv = db.session.get(Invoice, sale_id)
    assert inv.scrap_buy_price_at_sale == pytest.approx(_main_gram(2000.0) * RATIO, abs=0.001)
    _ratio(0.5)                                     # the policy moves: the sale's price does not
    from services.weight_position import collect_events
    events = collect_events(D(2041, 3, 1), D(2041, 3, 31, 23, 59))
    (lot,) = [l for l in events.openings if l.invoice_id == sale_id]
    assert lot.scrap_price == pytest.approx(_main_gram(2000.0) * RATIO, abs=0.001)


def _old_sale(when, cash, grams, market_main):
    """A sale recorded before the scrap price was saved: its market price alone."""
    from models import Invoice, InvoiceItem, db
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=when, total=cash,
                  total_tax=0.0, is_posted=True, status='paid', profit_weight_price_per_gram=market_main)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=cash, karat=21.0, weight=grams))
    db.session.flush()
    return inv


def test_a_sale_from_before_has_its_market_price_times_the_ratio(app):
    from services.weight_position import collect_events
    _ratio()
    inv = _old_sale(D(2041, 3, 2, 10), 1000.0, 2.0, 450.0)
    events = collect_events(D(2041, 3, 1), D(2041, 3, 31, 23, 59))
    (lot,) = [l for l in events.openings if l.invoice_id == inv.id]
    assert lot.scrap_price == pytest.approx(450.0 * RATIO)


def test_the_position_says_the_closing_price_and_the_price_now(app):
    """Two sales of 1 g at scrap prices 440 and 430 wait; the scrap price now
    is lower: the riyals buy more. Expected at the closing price, plus the
    price's move since, is what closing now would make."""
    from models import Invoice, db
    _ratio()
    for when, scrap in ((D(2041, 3, 2, 10), 440.0), (D(2041, 3, 3, 10), 430.0)):
        inv = _old_sale(when, 500.0, 1.0, 0.0)
        db.session.get(Invoice, inv.id).scrap_buy_price_at_sale = scrap
    db.session.flush()
    _market(D(2041, 3, 4, 9), 2000.0)
    now = _main_gram(2000.0) * RATIO

    body = _get('/api/reports/weight-position?as_of=2041-03-04', _headers('accountant')).get_json()
    assert body['closing_price'] == pytest.approx(435.0)
    assert body['price_now'] == pytest.approx(now, abs=0.001)
    assert body['expected_at_closing_price'] == pytest.approx(1000 / 435 - 2, abs=0.002)
    assert body['price_effect_since_sale'] == pytest.approx(1000 / now - 1000 / 435, abs=0.002)
    assert body['unrealized'] == pytest.approx(body['expected_at_closing_price'] + body['price_effect_since_sale'],
                                               abs=0.002)
    assert 'paid_average' in body and 'purchase_price' not in body
    assert {round(l['closing_price'], 2) for l in body['lots']} == {440.0, 430.0}

    card = _get('/api/reports/weight-position/summary?as_of=2041-03-04', _headers('accountant')).get_json()
    assert card['closing_price'] == pytest.approx(435.0)
    assert card['price_now'] == pytest.approx(now, abs=0.001)
    assert card['unrealized'] == pytest.approx(body['unrealized'], abs=0.002)
