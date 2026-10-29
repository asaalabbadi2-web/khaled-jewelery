"""An invoice's loss comes off its employee's points (POINTS-DEFICIT-1).

The owner, 29 Oct 2026: «العجز في فواتير البيع والشراء يجب أن يخصم من نقاط
الموظف» -- the deficit is the loss: a sale below its gold's cost (its cash
profit below nothing), a customer's scrap bought above the market's buy price
(its gold profit below nothing). From the day it is deployed (the settings'
points_deficits_from); below zero if it comes to that; in the race, the goals
and the bonuses alike -- one measure. Every invoice's profit was floored at
nothing, and a purchase's gold profit was saved floored: on the 27 Oct copy
50 sales lost 45,173 riyals and cost no one a point.

Run:
    python -m pytest tests/test_points_deficit.py -v
"""
import json
from datetime import date, datetime

import pytest

from models import Invoice, Settings, db
from tests.test_gold_bought_enters_its_stock import world  # noqa: F401 (fixture)
from tests.test_one_measure import MAY, _employee, _return, _sale

FROM = date(2031, 5, 10)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0})
    settings.points_deficits_from = FROM
    db.session.flush()
    yield


def test_a_sale_at_a_loss_takes_its_loss_off_its_seller():
    from services.performance_measures import measure
    seller, _ = _employee()
    _sale(seller.id, None, datetime(2031, 5, 11, 10), profit_cash=5000.0)
    _sale(seller.id, None, datetime(2031, 5, 12, 10), profit_cash=-1000.0, profit_gold=-0.4)
    assert measure('points', seller.id, *MAY) == pytest.approx(100.0 - 20.0)


def test_a_loss_before_the_day_costs_nothing():
    from services.performance_measures import measure
    seller, _ = _employee()
    _sale(seller.id, None, datetime(2031, 5, 3, 10), profit_cash=-1000.0, profit_gold=-0.4)
    assert measure('points', seller.id, *MAY) == pytest.approx(0.0)


def test_the_race_shows_points_below_nothing():
    from metrics.points_metric import PointsMetric
    seller, _ = _employee()
    sale = _sale(seller.id, None, datetime(2031, 5, 12, 10), profit_cash=-1000.0, profit_gold=-0.4)
    ranking, _ = PointsMetric(points_source='profit_cash', cash_amount_per_point=50.0).collect(
        [Invoice.id == sale.id], 10.0)
    assert [(r['id'], r['points']) for r in ranking if r['id'] == seller.id] == [(seller.id, -20)]


def test_a_return_of_a_sale_at_a_loss_gives_its_loss_back():
    from services.performance_measures import measure
    seller, _ = _employee()
    sale = _sale(seller.id, None, datetime(2031, 5, 12, 10), profit_cash=-1000.0, profit_gold=-0.4)
    _return(sale, datetime(2031, 5, 15, 10), 1.0)
    assert measure('points', seller.id, *MAY) == pytest.approx(0.0)


def test_scrap_bought_above_the_market_keeps_its_loss_and_costs_its_buyer(app, auth_headers, world):
    """10 g of 21k paid between the market's buy price and its sell price -- a
    loss, under the price that asks an approval: its gold profit is saved below
    nothing (it was saved as nothing), and it scores its loss -- for whoever it
    is credited to (actor_of: here its poster, it names no seller)."""
    from points.engine import compute_invoices_points
    from pricing.gold_price_service import get_current_gold_price
    from services.performance_measures import engine_settings
    Settings.query.first().points_deficits_from = date(2026, 1, 1)
    db.session.flush()
    paid = round(10.0 * get_current_gold_price()['price_per_gram_by_karat'][21] * 0.995, 2)
    resp = app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': world['holder'].id,
        'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
        'date': datetime(2026, 10, 29, 12).isoformat(),
        'total': paid, 'total_weight': 10.0, 'total_cost': paid, 'total_tax': 0.0, 'amount_paid': paid,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': paid}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': 10.0, 'standing_weight': 10.0, 'stones_weight': 0.0,
                   'price': paid, 'net': paid, 'quantity': 1}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    invoice = db.session.get(Invoice, resp.get_json()['id'])
    assert invoice.is_posted, 'under the price that asks an approval'
    assert invoice.profit_gold < 0, 'its loss, kept'
    assert invoice.profit_cash < 0, 'its loss in riyals too'
    assert compute_invoices_points([invoice], **engine_settings('points')) == pytest.approx(
        invoice.profit_cash / 50.0, abs=0.001)


def test_on_the_race_board_a_loss_has_no_share_and_the_team_is_its_sum(auth_headers):
    """Points below nothing on the board: its share of the race is nothing (a
    share is of the points earned), and the team's points are what its rows say."""
    from tests.test_the_race_card_adds_up import _employee as seller_of, _invoice, _race
    Settings.query.first().points_deficits_from = date(2026, 1, 1)
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 100.0})
    db.session.flush()
    loser, winner = seller_of(), seller_of()
    _invoice(loser, 'بيع', 1000.0, profit_cash=-500.0)                 # -5 points
    _invoice(winner, 'بيع', 3000.0, profit_cash=900.0)                 # 9 points
    body = _race(auth_headers)
    rows = {r['id']: r for r in body['ranking']}
    assert int(rows[loser.id]['score']) == -5
    assert rows[loser.id].get('share', 0.0) == 0.0
    assert all(0.0 <= r.get('share', 0.0) <= 1.0 for r in body['ranking'])
    assert body['admin_summary']['total_points'] == sum(int(r['score']) for r in body['ranking'])


def test_a_scrap_purchase_earns_its_cash_profit_as_a_sale_does(app, auth_headers, world):
    """The owner, 29 Oct 2026: «تأكد نقاط فواتير شراء الكسر تدعم احتساب الربح
    النقدي مثلها مثل فاتورة البيع». Its cash profit is what its gold is worth at
    the market's buy price less what was paid -- its gold profit at that price,
    and the value of any weight it kept off the books, as before; its points
    by the riyal, as a sale's. It earned grams x points_per_gram: 10 a gram
    where a sale's 428 riyals earn 8.56."""
    from points.engine import compute_invoices_points
    from pricing.buy_price import buy_price_ratio
    from pricing.gold_price_service import get_current_gold_price
    from services.performance_measures import engine_settings
    now = get_current_gold_price()
    buy_main = now['price_per_gram_main_karat'] * buy_price_ratio()
    paid = round(10.0 * now['price_per_gram_by_karat'][21] * buy_price_ratio() * 0.9, 2)   # 10 % under
    resp = app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': world['holder'].id,
        'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
        'date': datetime(2026, 10, 29, 12).isoformat(),
        'total': paid, 'total_weight': 10.0, 'total_cost': paid, 'total_tax': 0.0, 'amount_paid': paid,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': paid}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': 10.0, 'standing_weight': 10.0, 'stones_weight': 0.0,
                   'price': paid, 'net': paid, 'quantity': 1}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    invoice = db.session.get(Invoice, resp.get_json()['id'])
    assert invoice.profit_gold > 0
    assert invoice.profit_cash == pytest.approx(invoice.profit_gold * buy_main, abs=0.05)
    assert compute_invoices_points([invoice], **engine_settings('points')) == pytest.approx(
        invoice.profit_cash / 50.0, abs=0.01)
