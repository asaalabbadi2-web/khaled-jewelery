"""PRICE-BUY-1: the buy price is the market's times the settings' ratio, computed by the server.

The app multiplied by 0.98 twice -- the home price card's buy price and the
scrap purchase screen's fallback -- a business answer the UI made itself. The
owner, 14 Oct 2026: dynamic from the settings, read from the server.
"""
from datetime import datetime, timezone

import pytest

from app import app as flask_app
from models import GoldPrice, db
from pricing.buy_price import gram_prices
from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS

OUNCE = 4161.86


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
def fresh_price(monkeypatch):
    import routes.pricing as pricing
    monkeypatch.setattr(pricing, 'fetch_gold_quote', lambda: None)   # no internet
    row = GoldPrice(price=OUNCE, date=datetime.now(timezone.utc).replace(tzinfo=None))
    db.session.add(row)
    db.session.flush()
    yield
    # The settings PUT committed this row with it: it goes too.
    GoldPrice.query.filter_by(id=row.id).delete()
    db.session.commit()


@pytest.fixture
def restore_ratio(auth_headers):
    """PUT /settings commits -- the fence does not hold a commit; the ratio goes back."""
    yield
    assert _put(auth_headers, 0.98).status_code == 200


def _put(headers, ratio):
    return flask_app.test_client().put('/api/settings', headers=headers, json={'buy_price_ratio': ratio})


def test_the_arithmetic():
    gram_24 = OUNCE / TROY_OZ_TO_GRAMS * SAR_USD_PEG
    prices = gram_prices(OUNCE, ratio=0.97)
    assert prices['24'] == {'sell': round(gram_24, 2), 'buy': round(gram_24 * 0.97, 2)}
    assert prices['21']['sell'] == round(gram_24 * 21 / 24, 2)
    assert prices['21']['buy'] == round(gram_24 * 21 / 24 * 0.97, 2)


def test_the_gold_price_carries_the_buy_price_by_the_settings(app, auth_headers, fresh_price, restore_ratio):
    assert _put(auth_headers, 0.96).status_code == 200
    body = flask_app.test_client().get('/api/gold_price', headers=auth_headers).get_json()
    assert body['buy_price_ratio'] == pytest.approx(0.96)
    for karat in ('18', '21', '22', '24'):
        row = body['prices_per_gram'][karat]
        assert row['buy'] == pytest.approx(round(row['sell'] * 0.96, 2), abs=0.011)


@pytest.mark.parametrize('ratio', [0.3, 1.2, 'x'])
def test_a_ratio_out_of_bounds_is_refused(app, auth_headers, ratio):
    resp = _put(auth_headers, ratio)
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invalid_buy_price_ratio'
