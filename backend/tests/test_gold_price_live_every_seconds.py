"""PRICE-LIVE-1: the gold price is fetched every 15 seconds, and the table keeps a price a minute.

The owner, 29 Oct 2026: the shortest refresh that costs the app nothing -- 15
seconds («ابدأ»). It was a minute, the scheduler's floor (it took minutes and
looked every 30 seconds). Each fetch saved a row: 1,300 a day, 303,000 since
January on the 27 Oct copy -- and the day's scrap price reads them all. Now the
interval is in seconds (the settings', 10 at the least), and a price fetched in
the minute its last was saved replaces it: the screens read the newest, the
history keeps a price a minute, as it did.

Run:
    python -m pytest tests/test_gold_price_live_every_seconds.py -v
"""
from datetime import datetime, timedelta, timezone

import pytest

from models import GoldPrice, Settings, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


@pytest.fixture
def no_push(monkeypatch):
    import gold_price
    monkeypatch.setattr(gold_price, '_push_to_commerce', lambda price: None)
    return gold_price


def _cleanup(since):
    GoldPrice.query.filter(GoldPrice.date >= since).delete()
    db.session.commit()


def _at(monkeypatch, gold_price, when):
    monkeypatch.setattr(gold_price, '_utc_now', lambda: when)


def test_prices_in_a_minute_are_its_one_row_and_the_next_minute_a_new_one(app, no_push, monkeypatch):
    """Every 15 seconds over two minutes: two rows, each its minute's last price."""
    base = datetime(2041, 3, 3, 10, 0, 5)
    try:
        for i, price in enumerate([4000.0, 4001.0, 4002.0, 4003.0, 4004.0, 4005.0]):
            _at(monkeypatch, no_push, base + timedelta(seconds=15 * i))      # 10:00:05 .. 10:01:20
            no_push.save_gold_price(app, price)
        rows = GoldPrice.query.filter(GoldPrice.date >= base).order_by(GoldPrice.date).all()
        assert [(r.date.minute, r.price) for r in rows] == [(0, 4003.0), (1, 4005.0)]
        assert all(r.office_custom_fees_usd is not None for r in rows), 'saved with the office terms'
    finally:
        _cleanup(base)


def test_the_scheduler_runs_every_n_seconds(app):
    from gold_price_scheduler import GoldPriceScheduler
    scheduler = GoldPriceScheduler(app)
    scheduler._apply_schedule(True, 'interval', 15)
    (job,) = scheduler._scheduler.get_jobs('gold_price')
    assert (job.interval, job.unit) == (15, 'seconds')
    scheduler._apply_schedule(True, 'interval', 3)
    (job,) = scheduler._scheduler.get_jobs('gold_price')
    assert job.interval == 10, 'ten seconds at the least: the source is a public feed'


def test_the_settings_hold_the_interval_in_seconds(app, auth_headers):
    client = app.test_client()
    settings = Settings.query.first()
    before = settings.gold_price_auto_update_interval_seconds
    try:
        assert client.put('/api/settings', headers=auth_headers,
                          json={'gold_price_auto_update_interval_seconds': 15}).status_code == 200
        db.session.expire_all()
        assert Settings.query.first().gold_price_auto_update_interval_seconds == 15
        # An older screen still says minutes: it is the same interval, in seconds.
        assert client.put('/api/settings', headers=auth_headers,
                          json={'gold_price_auto_update_interval_minutes': 2}).status_code == 200
        db.session.expire_all()
        assert Settings.query.first().gold_price_auto_update_interval_seconds == 120
        refused = client.put('/api/settings', headers=auth_headers,
                             json={'gold_price_auto_update_interval_seconds': 5})
        assert refused.status_code == 400 and refused.get_json()['error'] == 'invalid_gold_price_interval'
    finally:
        client.put('/api/settings', headers=auth_headers,
                   json={'gold_price_auto_update_interval_seconds': before or 60})
