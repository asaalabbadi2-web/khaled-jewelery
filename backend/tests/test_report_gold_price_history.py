"""The gold price's history on the reports' contract, by day, week or month in Riyadh (REPORTS ت5-4, ADR-083).

«تاريخ أسعار الذهب» answered its own shape; it now answers the contract,
from the recorded prices (a basis of its own: neither entries nor
documents): each period its prices' count, its opening and closing riyals a
gram of the main karat (each price's own office gram price, OFFICE-PRICE-1),
its high and low, its average in riyals and in dollars an ounce, and its
change; the chart its average; a note the whole span's start, end and change.
Days are Riyadh's (tests/test_gold_price_clock.py keeps that of the route).

Run:
    python -m pytest tests/test_report_gold_price_history.py -v
"""
import datetime as dt

import pytest

from models import GoldPrice, db

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def prices():
    GoldPrice.query.delete()
    for when, usd in ((D(2044, 3, 1, 6), 4000.0), (D(2044, 3, 1, 18), 4100.0),     # 1 Mar, Riyadh
                      (D(2044, 3, 2, 6), 3900.0), (D(2044, 3, 20, 6), 4200.0)):
        db.session.add(GoldPrice(price=usd, date=when))
    db.session.flush()


def _history(by, start=dt.date(2044, 3, 1), end=dt.date(2044, 3, 31)):
    from services.reports.gold_price_history import gold_price_history
    return gold_price_history(start=start, end=end, by=by, now=D(2044, 4, 1))


def _rows(report):
    return {r['group']: r for r in report.rows if r.get('style') is None}


def test_by_day_each_day_opens_closes_and_moves(prices):
    from pricing.office_price import row_gram_price
    report = _history('day')
    first = _rows(report)['2044-03-01']
    assert first['points'] == 2
    assert first['avg_usd'] == pytest.approx(4050.0)
    gram = lambda usd: row_gram_price(GoldPrice(price=usd), 21)
    assert first['open'] == pytest.approx(gram(4000.0), abs=0.01)
    assert first['close'] == pytest.approx(gram(4100.0), abs=0.01)
    assert first['high'] == pytest.approx(gram(4100.0), abs=0.01) and first['low'] == pytest.approx(gram(4000.0), abs=0.01)
    assert first['change'] == pytest.approx(2.5, abs=0.01)
    assert report.basis == 'prices'
    assert report.to_dict()['chart'] == {'x': 'group', 'y': 'average', 'kind': 'line'}


def test_by_month_and_the_span_said(prices):
    report = _history('month')
    march = _rows(report)['2044-03']
    assert march['points'] == 4 and march['change'] == pytest.approx(5.0, abs=0.01)
    notes = [r['group'] for r in report.rows if r.get('style') == 'note']
    assert notes and '5.00%' in notes[0]


def test_by_week(prices):
    assert set(_rows(_history('week'))) == {'2044-W09', '2044-W11'}
