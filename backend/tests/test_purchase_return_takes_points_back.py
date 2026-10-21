"""A customer purchase's return takes back the points of the purchase it returns.

The owner (22 Oct 2026): «نعم» -- a purchase return takes back the buyer's
points as a sale return takes back the seller's (10 Oct 2026). Found on the
21 Oct backup: 3314 (3.3 g counted as 21k, its profit 0.136 g) was corrected by
admin on 20 Oct -- 1.5 g of it was 18k -- through a return (3430) that took no
point back: the points read sales' returns only.

The law, one engine for the race, the bonus and the goals (points/engine): a
purchase return takes back its purchase's points in the share it returns,
from the one who bought, in the period it is made; the one who recorded it
loses nothing. In the race card, the purchase's amount goes back with it.

Run:
    python -m pytest tests/test_purchase_return_takes_points_back.py -v
"""
from datetime import datetime, timedelta

import pytest

from models import Invoice, db
from tests.test_the_race_card_adds_up import _employee, _invoice, _race, race  # noqa: F401 (fixture)

ENGINE = dict(points_source='gold_weight', cash_amount_per_point=100.0, points_per_gram=10.0)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _purchase_and_return(returned_grams=3.3):
    """3.3 g bought for 1,400 (its profit 0.5 g); *returned_grams* of it returned
    for 600, recorded by someone else."""
    buyer, recorder = _employee(), _employee()
    bought = _invoice(buyer, 'شراء من عميل', 1400.0, profit_gold=0.5)
    returned = _invoice(recorder, 'مرتجع شراء', 600.0, original=bought)
    bought.total_weight, returned.total_weight = 3.3, returned_grams
    db.session.flush()
    return buyer, recorder, bought, returned


def test_a_purchase_return_takes_back_its_purchases_points_in_its_share():
    from points.engine import compute_invoices_points
    _, _, bought, returned = _purchase_and_return(returned_grams=1.65)
    alone = compute_invoices_points([bought], **ENGINE)
    assert alone == pytest.approx(5.0)
    assert compute_invoices_points([returned], **ENGINE) == pytest.approx(-2.5)
    assert compute_invoices_points([bought, returned], **ENGINE) == pytest.approx(2.5)


def test_the_race_takes_them_from_the_one_who_bought():
    from metrics.points_metric import PointsMetric
    buyer, recorder, bought, returned = _purchase_and_return()
    metric = PointsMetric(points_source='gold_weight')
    counts, _, _, purchase_amount, total, _, purchase_pts = metric._group_and_score([bought, returned], 10.0)
    assert total[buyer.id] == pytest.approx(0.0), 'the whole purchase returned: its points with it'
    assert purchase_pts[buyer.id] == pytest.approx(0.0)
    assert purchase_amount[buyer.id] == pytest.approx(1400.0 - 600.0)
    assert recorder.id not in total, 'the one who recorded the return loses nothing'
    assert 'مرتجع شراء' in metric.invoice_types


def test_the_bonus_and_the_goals_find_it_in_its_own_period_against_the_buyer():
    from points.engine import returns_against
    buyer, recorder, _, returned = _purchase_and_return()
    now = datetime.now()
    window = (now - timedelta(days=1), now + timedelta(days=1))
    assert returned.id in {r.id for r in returns_against(lambda o: o.employee_id == buyer.id, *window)}
    assert returned.id not in {r.id for r in returns_against(lambda o: o.employee_id == recorder.id, *window)}
    assert not returns_against(lambda o: o.employee_id == buyer.id, now + timedelta(days=2), now + timedelta(days=3))


def test_the_race_cards_purchases_are_its_buyers_purchases_less_returns(auth_headers, race):
    before = _race(auth_headers)['admin_summary']['total_purchase_amount']
    buyer, _, _, _ = _purchase_and_return(returned_grams=1.5)
    body = _race(auth_headers)
    assert body['admin_summary']['total_purchase_amount'] - before == pytest.approx(800.0)
    (row,) = [r for r in body['ranking'] if r['id'] == buyer.id]
    assert row['purchase_amount'] == pytest.approx(800.0)
