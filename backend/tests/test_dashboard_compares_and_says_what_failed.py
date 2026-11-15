"""The manager's dashboard compares each period with the one before it, and says what it could not read (the owner, 15 Nov 2026).

«اطلع على لوحة تحكم المدير وحللها ... وطبق جميع ما اقترحت». The laws:
  - each period beside the one before it, to the same point: today against
    yesterday to this hour, the month against the last one to this day (its
    last day when shorter), the year against the last one to this date --
    by the same readers;
  - the last seven days' sales and scrap bought, by those readers too: a day's
    sales are the summary's sales for that day;
  - what could not be read is listed in `unavailable` and sent as null --
    never a quiet zero; what was summed and never shown is gone.

Run:
    python -m pytest tests/test_dashboard_compares_and_says_what_failed.py -v
"""
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from routes.admin_dashboard import previous_periods


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _dashboard(headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/dashboard/admin', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_each_period_against_the_one_before_it_to_the_same_point():
    p = previous_periods(datetime(2026, 11, 15, 10, 30))
    assert p['today'][1] == (datetime(2026, 11, 14), datetime(2026, 11, 14, 10, 30))
    assert p['month'][1] == (datetime(2026, 10, 1), datetime(2026, 10, 16))
    assert p['year'][1] == (datetime(2025, 1, 1), datetime(2025, 11, 16))
    # a longer month against a shorter one: to its last day
    march = previous_periods(datetime(2026, 3, 31, 9, 0))
    assert march['month'][1] == (datetime(2026, 2, 1), datetime(2026, 3, 1))


def test_the_dashboard_sends_the_previous_and_the_seven_days(auth_headers):
    d = _dashboard(auth_headers)
    assert d['unavailable'] == []
    for period in ('today', 'month', 'year'):
        block = d['sales_purchases_summary'][period]
        assert set(block['previous']) == {'sales', 'purchases', 'scrap_customers', 'office_settlements',
                                          'expenses', 'revenues'}
        assert {'start', 'end'} <= set(block['previous_range'])
    daily = d['series']['daily']
    assert len(daily) == 7 and daily[-1]['day'] == datetime.now().date().isoformat()
    assert daily[-1]['sales'] == round(d['sales_purchases_summary']['today']['sales']['total_value'], 2), \
        "a day's sales are the summary's: one reader"


def test_what_was_summed_and_never_shown_is_gone(auth_headers):
    d = _dashboard(auth_headers)
    for gone in ('sales_today', 'purchases_today', 'today_profit', 'today_profit_margin_pct', 'yesterday_profit',
                 'today_profit_vs_yesterday_pct'):
        assert gone not in d['kpis'], gone
    for gone in ('inventory_value', 'avg_cost_per_gram', 'profit_margin_pct'):
        assert gone not in d['valuation'], gone
    assert 'gold_price_change_pct' not in d['global_snapshot']
    assert 'net_financial_position' not in d['global_snapshot'], "one net: the standing's, with what is owed"
    assert set(d['series']) == {'daily'}


def test_safes_not_read_are_said_and_nothing_built_on_them_is_zero(auth_headers, monkeypatch):
    import routes.admin_dashboard as dashboard

    def broken(*args, **kwargs):
        raise RuntimeError('the ledger is not there')
    monkeypatch.setattr(dashboard, 'safe_box_balances_bulk', broken)
    d = _dashboard(auth_headers)
    assert 'safes' in d['unavailable']
    assert d['kpis']['gold_by_karat'] is None and d['kpis']['cash_balance'] is None
    assert d['liquidity'] == {'cash_available': None, 'cash_in_hand': None, 'cash_in_banks': None}


def test_a_period_not_read_is_said_not_emptied(auth_headers, monkeypatch):
    import services.income_accounts as income

    def broken():
        raise RuntimeError('no chart')
    monkeypatch.setattr(income, 'operating_expense_account_ids', broken)
    d = _dashboard(auth_headers)
    assert {'summary_today', 'summary_month', 'summary_year'} <= set(d['unavailable'])
    assert 'month' not in d['sales_purchases_summary'], 'not an empty period that reads as nothing sold'
