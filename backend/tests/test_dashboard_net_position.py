"""The net position is what the shop has less what it owes (the owner, 15 Nov 2026).

«صافي المركز المالي» was the cash and the gold with nothing owed taken off --
11,088,017 on the 14 Nov copy, 10,700,774 net of what was owed. The laws:
  - has: the liquidity (the safes, the banks, the net on its way), the gold
    safes' grams and what is owed us in grams at the price, what is owed us
    in riyals;
  - owes: what we owe the parties in riyals, and in grams at the price; the
    salaries; the VAT; each period expense's months accrued and unpaid --
    not its months to come;
  - a part not read leaves the net not read.

Run:
    python -m pytest tests/test_dashboard_net_position.py -v
"""
import pytest
from flask import g

from app import app as flask_app
from services.dashboard_net import compose, net_position

POSITIONS = {
    'customers': {'owe_us_cash': 500.0, 'we_owe_cash': 200.0, 'owe_us_gold': 1.0, 'we_owe_gold': 2.0},
    'suppliers': {'owe_us_cash': 0.0, 'we_owe_cash': 187260.01, 'owe_us_gold': 0.659, 'we_owe_gold': 281.24},
}
UPCOMING = {
    'period_expenses': [{'id': 16, 'to_pay': 63000.0, 'owed_now': 42000.0, 'by': '2026-12-31'}],
    'salaries': {'amount': 21035.0, 'count': 2},
    'suppliers': {'cash': 187260.01, 'gold': 281.24, 'count': 12},
    'vat': 1.12,
    'total_cash': 271296.13,
}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def test_has_less_owes_each_by_its_part():
    said = compose(cash=241019.85, transit=72100.0, gold_grams=26200.136, price=413.2,
                   positions=POSITIONS, upcoming=UPCOMING)
    has = 241019.85 + 72100.0 + (26200.136 + 1.0 + 0.659) * 413.2 + 500.0
    owes = (200.0 + 187260.01) + (2.0 + 281.24) * 413.2 + 21035.0 + 1.12 + 42000.0
    assert said['has'] == pytest.approx(has, abs=0.01)
    assert said['owes'] == pytest.approx(owes, abs=0.01)
    assert said['net'] == pytest.approx(has - owes, abs=0.01)


def test_a_period_expense_owes_its_months_accrued_not_its_months_to_come():
    said = compose(cash=0, transit=0, gold_grams=0, price=400.0, positions={
        'customers': dict.fromkeys(('owe_us_cash', 'we_owe_cash', 'owe_us_gold', 'we_owe_gold'), 0.0),
        'suppliers': dict.fromkeys(('owe_us_cash', 'we_owe_cash', 'owe_us_gold', 'we_owe_gold'), 0.0)},
        upcoming={**UPCOMING, 'salaries': {'amount': 0.0, 'count': 0}, 'vat': 0.0})
    assert said['owes'] == 42000.0, 'the 42,000 owed now -- not the 63,000 left to pay by December'


def test_a_part_not_read_leaves_the_net_not_read():
    with pytest.raises(ValueError):
        net_position(positions=None, clearing={'total_net': 0}, upcoming=UPCOMING)
    with pytest.raises(ValueError):
        net_position(positions=POSITIONS, clearing={'total_net': 0},
                     upcoming={**UPCOMING, 'suppliers': {'cash': None, 'gold': None, 'count': None}})


def test_the_standing_carries_it_or_says_it_null(auth_headers, monkeypatch):
    from datetime import datetime
    from models import GoldPrice, db
    db.session.add(GoldPrice(price=2400.0, date=datetime(2026, 10, 14, 9, 0)))
    db.session.flush()
    g.pop('current_user', None)
    standing = flask_app.test_client().get('/api/dashboard/admin/standing', headers=auth_headers).get_json()
    assert standing['net_position'] is not None and {'net', 'has', 'owes', 'parts', 'price'} <= set(
        standing['net_position'])

    import services.dashboard_positions as positions

    def broken():
        raise RuntimeError('the parties could not be read')
    monkeypatch.setattr(positions, 'positions', broken)
    g.pop('current_user', None)
    standing = flask_app.test_client().get('/api/dashboard/admin/standing', headers=auth_headers).get_json()
    assert standing['positions'] is None and standing['net_position'] is None, 'not a net with the debts left out'
