"""The gold price's clock: stored in UTC, read in UTC, shown as Riyadh time (the owner, 2 Oct 2026).

Since 28 Jul 2026 save_gold_price stores gold_price.date as naive UTC (and the
store reads it so). The readers kept Riyadh's wall clock:

  - /api/gold_price compared the stored UTC time with datetime.now() -- three
    hours apart -- so every price looked older than five minutes and the screen
    fetched from the internet on every read, though the scheduler had saved one
    a minute before;
  - «today's opening» began at 03:00 Riyadh time, the UTC midnight;
  - the times went out with no zone, and each screen guessed one.

The laws: a price saved a minute ago is served from the database; the opening
is the first price after Riyadh's midnight; every time goes out marked UTC;
the 24-hour chart spans the 24 hours, not their first 48 minutes. Prices
before 28 Jul stay as stored (the owner).

Run:
    python -m pytest tests/test_gold_price_clock.py -v
"""
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import GoldPrice, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def clean_prices():
    GoldPrice.query.delete()
    db.session.flush()


@pytest.fixture
def no_internet(monkeypatch):
    calls = []

    def fake_fetch():
        calls.append(1)
        return 4100.0
    import routes.pricing as pricing
    monkeypatch.setattr(pricing, 'fetch_gold_price', fake_fetch)
    return calls


def _price(when_utc, usd):
    db.session.add(GoldPrice(price=usd, date=when_utc))
    db.session.flush()


def test_a_price_saved_a_minute_ago_is_served_from_the_database(auth_headers, clean_prices, no_internet):
    _price(datetime.utcnow() - timedelta(minutes=1), 4177.28)
    body = flask_app.test_client().get('/api/gold_price', headers=auth_headers).get_json()
    assert no_internet == [], 'fetched from the internet though the price was a minute old'
    assert body['price_usd_per_oz'] == 4177.28
    assert body['source'] == 'Database (Cached)'


def test_a_price_older_than_five_minutes_is_refreshed(auth_headers, clean_prices, no_internet):
    _price(datetime.utcnow() - timedelta(minutes=6), 4177.28)
    flask_app.test_client().get('/api/gold_price', headers=auth_headers)
    assert no_internet == [1]


def test_the_opening_is_the_first_price_after_riyadh_midnight(auth_headers, clean_prices, no_internet, monkeypatch):
    from pricing import price_clock
    now = datetime(2026, 10, 2, 9, 0)                      # 12:00 in Riyadh
    monkeypatch.setattr(price_clock, 'utc_now', lambda: now)
    _price(datetime(2026, 10, 1, 20, 30), 4000.0)          # 23:30 Riyadh, the day before
    _price(datetime(2026, 10, 1, 21, 30), 4050.0)          # 00:30 Riyadh: today's opening
    _price(datetime(2026, 10, 2, 8, 59), 4100.0)           # a minute ago
    body = flask_app.test_client().get('/api/gold_price', headers=auth_headers).get_json()
    assert no_internet == []
    assert body['opening_price_usd_per_oz'] == 4050.0
    assert body['opening_date'] == '2026-10-01T21:30:00Z'


def test_every_time_goes_out_marked_utc(auth_headers, clean_prices, no_internet):
    _price(datetime.utcnow() - timedelta(minutes=1), 4177.28)
    c = flask_app.test_client()
    body = c.get('/api/gold_price', headers=auth_headers).get_json()
    assert body['date'].endswith('Z') and body['opening_date'].endswith('Z')
    points = c.get('/api/gold_price/24h', headers=auth_headers).get_json()['points']
    assert points and all(p['timestamp'].endswith('Z') for p in points)


def test_the_24h_chart_spans_the_day_not_its_first_hour(auth_headers, clean_prices):
    now = datetime.utcnow()
    for minutes in range(0, 24 * 60 - 1, 10):            # a price every ten minutes, 144 of them
        _price(now - timedelta(minutes=minutes), 4000.0 + minutes)
    points = flask_app.test_client().get('/api/gold_price/24h', headers=auth_headers).get_json()['points']
    assert len(points) <= 48
    first = datetime.fromisoformat(points[0]['timestamp'].rstrip('Z'))
    last = datetime.fromisoformat(points[-1]['timestamp'].rstrip('Z'))
    assert last - first > timedelta(hours=23), (first, last)
    assert abs(last - now) < timedelta(minutes=1), 'the latest price is the chart\'s last point'


def test_the_history_report_counts_days_in_riyadh(auth_headers, clean_prices):
    """A price at 01:00 Riyadh belongs to that day, not the UTC one before."""
    _price(datetime(2026, 9, 30, 22, 0), 4000.0)           # 1 Oct 01:00 Riyadh
    resp = flask_app.test_client().get(
        '/api/reports/gold_price_history?start_date=2026-10-01&end_date=2026-10-01', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    text = resp.get_data(as_text=True)
    assert '4000' in text, 'the 01:00 price fell outside its Riyadh day'
