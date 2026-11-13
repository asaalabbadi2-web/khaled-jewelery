"""The day's gold price, for the manager's gold price card (DASH-11).

The owner, 30 Oct 2026: the card is to say the main karat's selling and buy
price, live, and the day's move -- from its opening, its high and low, and a
line of it. /gold_price/24h?day=today: the day in Riyadh, each point the main
karat's price a gram as the office makes it (row_gram_price -- the screen
never makes it from the ounce), the high and low over every row, before the
points are thinned. Without ?day, the 24 hours, the same: each point both
series, and each series' high and low (the home bar's chart, 13 Nov 2026).

Run:
    python -m pytest tests/test_gold_price_today_for_the_dashboard.py -v
"""
from datetime import timedelta

import pytest

from models import GoldPrice
from pricing import price_clock
from tests.test_gold_price_clock import _price, app, clean_prices, rollback_after_each  # noqa: F401


def test_the_day_its_main_karat_price_and_its_high_and_low(auth_headers, clean_prices):  # noqa: F811
    from flask import current_app
    from pricing.office_price import row_gram_price
    from utils import get_main_karat
    now = price_clock.utc_now()
    start, _ = price_clock.riyadh_day_bounds_utc(price_clock.riyadh_today(now))
    _price(start - timedelta(minutes=5), 9000.0)                  # yesterday's: not the day's
    span = max((now - start).total_seconds(), 200.0)
    for i in range(100):                                           # thinned to 48
        usd = 4000.0 + (300.0 if i == 37 else 0.0) - (250.0 if i == 62 else 0.0)
        _price(start + timedelta(seconds=1 + i * (span - 2) / 100), usd)

    answer = current_app.test_client().get('/api/gold_price/24h?day=today', headers=auth_headers).get_json()
    main = int(get_main_karat())
    rows = GoldPrice.query.filter(GoldPrice.date >= start).order_by(GoldPrice.date).all()
    grams = [row_gram_price(r, main) for r in rows]
    assert answer['main_karat'] == main
    assert answer['high_main_karat'] == pytest.approx(max(grams), abs=0.01), 'over every row'
    assert answer['low_main_karat'] == pytest.approx(min(grams), abs=0.01), 'over every row'
    assert answer['count'] <= 48
    assert all(p['price_usd_per_oz'] != 9000.0 for p in answer['points']), "yesterday's is not the day's"
    assert all(p['price_main_karat'] > 0 for p in answer['points'])


def test_the_24_hours_carry_the_main_karat_and_the_ounce_each_with_its_high_and_low(auth_headers, clean_prices):  # noqa: F811
    """The home bar's chart (the owner, 13 Nov 2026): the main karat's price a
    gram by default, the ounce at a toggle -- both the server's, each with its
    own high and low over every row of the 24 hours, before the thinning."""
    from flask import current_app
    from pricing.office_price import row_gram_price
    from utils import get_main_karat
    now = price_clock.utc_now()
    _price(now - timedelta(hours=25), 9000.0)                     # older than 24 hours: not in it
    for i in range(100):                                           # thinned to 48
        usd = 4000.0 + (300.0 if i == 37 else 0.0) - (250.0 if i == 62 else 0.0)
        _price(now - timedelta(hours=23) + timedelta(minutes=13 * i), usd)
    answer = current_app.test_client().get('/api/gold_price/24h', headers=auth_headers).get_json()
    main = int(get_main_karat())
    rows = GoldPrice.query.filter(GoldPrice.date >= now - timedelta(hours=24)).order_by(GoldPrice.date).all()
    grams = [row_gram_price(r, main) for r in rows]
    assert answer['main_karat'] == main
    assert answer['high_main_karat'] == pytest.approx(max(grams), abs=0.01), 'over every row'
    assert answer['low_main_karat'] == pytest.approx(min(grams), abs=0.01), 'over every row'
    assert (answer['high_usd_per_oz'], answer['low_usd_per_oz']) == (4300.0, 3750.0), 'over every row'
    assert answer['count'] <= 48
    assert all(p['price_usd_per_oz'] != 9000.0 for p in answer['points'])
    assert all(p['price_main_karat'] == pytest.approx(row_gram_price(_row(p), main), abs=0.01)
               for p in answer['points']), "each point's own row, by its own terms"


def _row(point):
    from datetime import datetime
    when = datetime.fromisoformat(point['timestamp'].replace('Z', '+00:00')).replace(tzinfo=None)
    return GoldPrice.query.filter(GoldPrice.date == when).first()
