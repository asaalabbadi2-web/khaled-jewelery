"""Each karat's move since the day's opening, its spread, and the ounce's move --
the server's (the owner, 13 Nov 2026: the home bar showed every karat with the
main karat's percent, and the ounce with it too; the screen made them).

Each karat's change is its own selling price now less its own at the opening
(OFFICE-PRICE-1: the office's karats are not the ounce's, each moves by its
own terms), its percent of its own opening; the spread is its sell less its
buy; the ounce's change and percent are the ounce's own.

Run:
    python -m pytest tests/test_gold_price_moves.py -v
"""
from datetime import timedelta

import pytest

from pricing import price_clock
from pricing.buy_price import ounce_move, price_moves
from tests.test_gold_price_clock import _price, app, clean_prices, no_internet, rollback_after_each  # noqa: F401


def test_each_karat_moves_by_its_own_price_and_the_spread_is_its_own():
    now = {'18': {'sell': 353.45, 'buy': 347.25}, '21': {'sell': 412.35, 'buy': 405.10}}
    opening = {'18': {'sell': 351.85, 'buy': 345.70}, '21': {'sell': 410.50, 'buy': 403.30}}
    moves = price_moves(now, opening)
    assert moves['21'] == {'change': 1.85, 'change_percent': 0.45, 'spread': 7.25}
    assert moves['18'] == {'change': 1.6, 'change_percent': 0.45, 'spread': 6.2}
    assert price_moves({'21': {'sell': 400.0, 'buy': 390.0}}, {})['21'] == {
        'change': None, 'change_percent': None, 'spread': 10.0}, 'no opening: no move, a spread'


def test_the_ounce_moves_by_itself():
    assert ounce_move(4105.20, 4108.30) == {'change': -3.1, 'change_percent': -0.08}
    assert ounce_move(4105.20, None) == {'change': None, 'change_percent': None}


def test_the_price_answer_carries_the_moves(auth_headers, clean_prices, no_internet):  # noqa: F811
    from flask import current_app
    now = price_clock.utc_now()
    start, _ = price_clock.riyadh_day_bounds_utc(price_clock.riyadh_today(now))
    _price(max(start + timedelta(seconds=1), now - timedelta(minutes=3)), 4000.0)    # the day's opening
    _price(now - timedelta(minutes=1), 4040.0)
    body = current_app.test_client().get('/api/gold_price', headers=auth_headers).get_json()
    assert set(body['moves_per_gram']) == {'18', '21', '22', '24'}
    for karat, move in body['moves_per_gram'].items():
        sell, opened = body['prices_per_gram'][karat]['sell'], body['opening_prices_per_gram'][karat]['sell']
        assert move['change'] == pytest.approx(sell - opened, abs=0.01), karat
        assert move['change_percent'] == pytest.approx((sell - opened) / opened * 100, abs=0.01), karat
        assert move['spread'] == pytest.approx(sell - body['prices_per_gram'][karat]['buy'], abs=0.01), karat
    assert body['ounce_move'] == {'change': 40.0, 'change_percent': 1.0}
