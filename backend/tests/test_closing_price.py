"""What waits is measured at the closing office's price -- at its sale and now (ADR-048, decision 5 restated again).

The owner (23 Oct 2026): «متوسط سعر ذهب الكسر لوزن الفواتير التي لم تسكر حتى
الآن. مثلًا سجلت فاتورة بيع وزن 1 جرام كان سعر الكسر وقتها 440، فاتورة بعدها
435، وبعدها 430، وكلهن بنفس الوزن 1 جرام: عندها سيكون متوسط سعر التسكير =
435». Then (2 Nov 2026): «أفضل للتسكيرات ان يكون السعر هو سعر المكتب وليس سعر
المكتب ×0.99 عكس شراء كسر» -- the shop closes at the office, so the buy ratio
(a customer's scrap) is no part of it.

A sale's closing price is the price it was sold at -- the office's gram of the
main karat, kept with it when it was recorded (frozen). A sale kept with a
scrap price (23 Oct to 2 Nov; those waiting from before the office's terms
were re-priced at the office) is read back by the ratio it was saved with,
0.99 throughout. The closing price of what waits is its sales' prices weighted
by their grams still waiting; it is valued now at the office's price now. One
price for a sale: its card's «المتوقَّع وقت البيع» is the position's.

Run:
    python -m pytest tests/test_closing_price.py -v
"""
import datetime as dt
import uuid

import pytest

from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
from services.weight_position import Events, Lot, closing_price, performance
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


def _lot(grams, price, cash=None, when=D(2041, 3, 1)):
    return Lot(f'بيع {grams}', when, cash if cash is not None else grams * price, grams, price)


def test_the_owner_s_example_three_grams_at_440_435_430_close_at_435():
    assert closing_price([_lot(1, 440), _lot(1, 435), _lot(1, 430)]) == pytest.approx(435.0)


def test_it_is_weighted_by_the_grams_still_waiting():
    half_closed = _lot(2, 440)
    half_closed.grams_open = 1.0
    assert closing_price([half_closed, _lot(3, 430)]) == pytest.approx((440 + 3 * 430) / 4)
    assert closing_price([Lot('إيرادات', D(2041, 3, 1), 500, 0.0)]) is None


def test_the_price_of_a_day_is_the_office_s_last_with_no_buy_ratio(app):
    from services.weight_position import office_prices
    _ratio()
    _market(D(2041, 3, 1, 9), 2000.0)
    _market(D(2041, 3, 1, 15), 2100.0)
    _market(D(2041, 3, 3, 10), 2200.0)
    price_on = office_prices(dt.date(2041, 3, 5))
    assert price_on(dt.date(2041, 3, 1))[0] == pytest.approx(_main_gram(2100.0)), 'the office, not ×0.97'
    assert price_on(dt.date(2041, 3, 2))[0] == pytest.approx(_main_gram(2100.0)), 'a quiet day keeps it'
    assert price_on(dt.date(2041, 3, 5))[0] == pytest.approx(_main_gram(2200.0))


def test_a_sale_closes_at_the_price_it_was_sold_at(app, auth_headers, world):
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
    assert inv.scrap_buy_price_at_sale is None, 'a scrap price is no part of its closing'
    _ratio(0.5)                                     # the buy ratio moves: the sale's price does not
    from services.weight_position import collect_events
    events = collect_events(D(2041, 3, 1), D(2041, 3, 31, 23, 59))
    (lot,) = [l for l in events.openings if l.invoice_id == sale_id]
    assert lot.price_at_sale == pytest.approx(_main_gram(2000.0), abs=0.001)


def _old_sale(when, cash, grams, market_main, scrap=None):
    """A sale recorded before: its price, and the scrap price it was kept with (if any)."""
    from models import Invoice, InvoiceItem, db
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=when, total=cash,
                  total_tax=0.0, is_posted=True, status='paid', profit_weight_price_per_gram=market_main,
                  scrap_buy_price_at_sale=scrap)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=cash, karat=21.0, weight=grams))
    db.session.flush()
    return inv


def test_a_sale_kept_with_a_scrap_price_is_read_back_by_its_ratio(app):
    """Re-priced at the office (the ounce's market kept 450, the office 455):
    it closes at 455; one never kept with a scrap price, at its own price."""
    from services.weight_position import collect_events
    _ratio(0.99)
    repriced = _old_sale(D(2041, 3, 2, 10), 1000.0, 2.0, 450.0, scrap=round(455.0 * 0.99, 4))
    plain = _old_sale(D(2041, 3, 2, 11), 1000.0, 2.0, 450.0)
    events = collect_events(D(2041, 3, 1), D(2041, 3, 31, 23, 59))
    price = {l.invoice_id: l.price_at_sale for l in events.openings}
    assert price[repriced.id] == pytest.approx(455.0, abs=0.001)
    assert price[plain.id] == pytest.approx(450.0)


def test_the_position_says_the_closing_price_and_the_price_now(app):
    """Two sales of 1 g at 440 and 430 wait; the office now is lower: the
    riyals buy more. Expected at the closing price, plus the price's move
    since, is what closing now would make."""
    _ratio()
    for when, price in ((D(2041, 3, 2, 10), 440.0), (D(2041, 3, 3, 10), 430.0)):
        _old_sale(when, 500.0, 1.0, price)
    _market(D(2041, 3, 4, 9), 2000.0)
    now = _main_gram(2000.0)

    body = _get('/api/reports/weight-position?as_of=2041-03-04', _headers('accountant')).get_json()
    assert body['closing_price'] == pytest.approx(435.0)
    assert body['price_now'] == pytest.approx(now, abs=0.001)
    assert body['expected_at_closing_price'] == pytest.approx(1000 / 435 - 2, abs=0.002)
    assert body['price_effect_since_sale'] == pytest.approx(1000 / now - 1000 / 435, abs=0.002)
    assert body['unrealized'] == pytest.approx(body['expected_at_closing_price'] + body['price_effect_since_sale'],
                                               abs=0.002)
    assert 'paid_average' in body and 'purchase_price' not in body
    assert {round(l['closing_price'], 2) for l in body['lots']} == {440.0, 430.0}
    for lot in body['lots']:
        assert lot['expected_at_sale'] == pytest.approx(500 / lot['closing_price'] - 1, abs=0.002), \
            'its card and the position, one price'

    card = _get('/api/reports/weight-position/summary?as_of=2041-03-04', _headers('accountant')).get_json()
    assert card['closing_price'] == pytest.approx(435.0)
    assert card['price_now'] == pytest.approx(now, abs=0.001)
    assert card['unrealized'] == pytest.approx(body['unrealized'], abs=0.002)


def test_the_fifth_layer_says_its_sales_waiting_and_the_price_apart():
    """One waits from before (1 g for 500 at 400), one is sold in the month
    (1 g for 420 at 400); the office ends the month at 380. ⑤ is how what
    waits moved: what its sales would make at their own price, and the
    price's move since -- the two, and nothing else, make it."""
    before = _lot(1, 400, cash=500, when=D(2041, 5, 20, 10))
    sold = _lot(1, 400, cash=420, when=D(2041, 6, 10, 10))
    prices = lambda day: ((400.0 if day < dt.date(2041, 6, 15) else 380.0), 'test')   # noqa: E731
    result = performance(dt.date(2041, 6, 1), dt.date(2041, 6, 30), Events(openings=[before, sold]), prices)
    parts = result['price_effect_parts']
    assert parts['waiting_sales'] == pytest.approx(420 / 400 - 1, abs=0.001), 'the sale of the month, at its price'
    assert parts['price'] == pytest.approx(920 / 380 - 920 / 400, abs=0.001), 'both, from 400 to 380'
    assert parts['waiting_sales'] + parts['price'] == pytest.approx(result['layers']['price_effect'], abs=0.001)
