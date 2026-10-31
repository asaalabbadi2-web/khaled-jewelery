"""PRICE-MARKET-1: a closed gold market is recorded closed, not refreshed for nothing.

The owner, 31 Oct 2026: «سعر الذهب العالمي يغلق في عطلة نهاية الأسبوع وغيرها،
أليس من الأفضل أن يُسجَّل مغلق بدل التحديث التلقائي دون جدوى؟» -- every
Saturday and Sunday of October saved ~1,300 rows at one price, and asked the
source every 15 seconds. The source says when it last quoted (Swissquote's ts:
21:55 UTC on Friday, all weekend): older than the policy's minutes, the market
is closed -- nothing is saved, the source is asked once in a while, and the
answer says so. And every source failing no longer passes the last price off
as a new one.

Run:
    python -m pytest tests/test_gold_market_closed.py -v
"""
from datetime import datetime, timedelta

import pytest

from models import GoldMarketState, GoldPrice, db

NOW = datetime(2041, 3, 2, 12, 0, 0)            # a Saturday's noon, UTC


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def market(app, monkeypatch):
    """The clock at NOW, no push to the storefront; the state and the rows after
    NOW cleaned whatever the test commits."""
    import gold_price
    from pricing import price_clock
    monkeypatch.setattr(price_clock, 'utc_now', lambda: NOW)
    monkeypatch.setattr(gold_price, '_utc_now', lambda: NOW)
    monkeypatch.setattr(gold_price, '_push_to_commerce', lambda price: None)
    GoldMarketState.query.delete()
    db.session.commit()
    yield gold_price
    GoldPrice.query.filter(GoldPrice.date >= NOW - timedelta(days=1)).delete()
    GoldMarketState.query.delete()
    db.session.commit()


def _quote(gold_price, minutes_old):
    return lambda: gold_price.Quote(4000.0, NOW - timedelta(minutes=minutes_old), 'test')


def _rows():
    return GoldPrice.query.filter(GoldPrice.date >= NOW - timedelta(days=1)).count()


def test_an_old_quote_is_a_closed_market_and_nothing_is_saved(app, market):
    assert market.refresh_gold_price(app, fetch=_quote(market, 14 * 60)) == 'closed'   # Friday's close
    state = GoldMarketState.query.one()
    assert state.is_open is False and state.last_quote_at == NOW - timedelta(minutes=14 * 60)
    assert _rows() == 0, 'no row for a closed market'


def test_a_fresh_quote_is_an_open_market_and_its_price_saved(app, market):
    assert market.refresh_gold_price(app, fetch=_quote(market, 1)) == 'saved'
    assert GoldMarketState.query.one().is_open is True
    assert _rows() == 1


def test_a_closed_market_is_asked_once_in_a_while(app, market):
    market.refresh_gold_price(app, fetch=_quote(market, 600))
    assert market.refresh_due(NOW + timedelta(seconds=15)) is False, 'not at every tick'
    assert market.refresh_due(NOW + market.closed_check_every()) is True
    market.refresh_gold_price(app, fetch=_quote(market, 1))
    assert market.refresh_due(NOW + timedelta(seconds=15)) is True, 'open: at every tick'


def test_the_scheduler_does_not_ask_a_closed_market_at_every_tick(app, market, monkeypatch):
    from gold_price_scheduler import GoldPriceScheduler
    import gold_price_scheduler
    market.refresh_gold_price(app, fetch=_quote(market, 600))
    asked = []
    monkeypatch.setattr(gold_price_scheduler, 'refresh_gold_price', lambda a: asked.append(1) or 'closed')
    GoldPriceScheduler(app).update_from_internet()
    assert asked == []


def test_no_source_is_unavailable_not_the_last_price_again(app, market, monkeypatch):
    for name in ('_fetch_from_swissquote', '_fetch_from_goldprice_org', '_fetch_from_yahoo'):
        monkeypatch.setattr(market, name, lambda: None)
    assert market.fetch_gold_price() is None, 'it returned the last saved price as a new one'
    assert market.refresh_gold_price(app) == 'unavailable'
    assert GoldMarketState.query.one().unavailable_since == NOW
    assert _rows() == 0


def test_the_price_answer_says_the_market_closed_and_does_not_ask_again(app, market, auth_headers, monkeypatch):
    from flask import g
    import routes.pricing as pricing
    db.session.add(GoldPrice(price=3990.0, date=NOW - timedelta(hours=14)))   # Friday's last
    db.session.commit()
    market.refresh_gold_price(app, fetch=_quote(market, 14 * 60))
    asked = []
    monkeypatch.setattr(pricing, 'fetch_gold_quote', lambda: asked.append(1))
    g.pop('current_user', None)
    answer = app.test_client().get('/api/gold_price', headers=auth_headers).get_json()
    assert answer['market']['open'] is False and answer['market']['last_quote_at']
    assert answer['price_usd_per_oz'] == 3990.0, "the last price, Friday's"
    assert asked == [], 'checked a moment ago: not asked again'
