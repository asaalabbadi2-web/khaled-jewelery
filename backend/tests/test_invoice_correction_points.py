"""A correction's points: in its own period, from the one who made the invoice (ت-2).

The owner (22 Oct 2026): the line is corrected in place, and the points move
in the period of the correction -- the invoice's profit stays as it was paid
(as a return's, 10 Oct 2026). 3314 earned 0.136 g on 3.3 g counted as 21k; 1.5
g of it was 18k: its right profit is nothing, so its buyer's points lose 0.136
g's worth in the correction's period, and the period it was paid in stays.

One engine for the race, the bonus and the goals (points/engine):
  - a correction is its points' difference -- the right profit's points less
    the paid's -- against the original's actor, in the correction's period;
    the one who made the correction loses nothing;
  - a mode that reads the invoice's lines (the weight sold) reads a corrected
    invoice as it was posted: its weight less its corrections' differences.

Run:
    python -m pytest tests/test_invoice_correction_points.py -v
"""
from datetime import datetime, timedelta

import pytest

from models import Invoice, InvoiceCorrection, SafeBox, db
from tests.test_gold_bought_enters_its_stock import world  # noqa: F401 (fixture)
from tests.test_invoice_correction import _bought, _correct

GOLD = dict(points_source='gold_weight', cash_amount_per_point=100.0, points_per_gram=10.0)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _3314(headers, w):
    """Bought: 3.3 g of 21k; corrected: 1.5 g of it is 18k -- weighed less for
    the same riyals."""
    invoice, line = _bought(headers, w)
    original = Invoice.query.get(invoice['id'])
    original.profit_gold = 0.136                      # what it earned, as paid
    db.session.flush()
    resp = _correct(headers, invoice['id'], {
        'line_id': line.id, 'reason': 'تصحيح عيار',
        'safe_box_id': SafeBox.query.filter_by(account_id=w['custody'].id).one().id,
        'lines': [{'karat': 21, 'weight': 1.8, 'price': 180.0}, {'karat': 18, 'weight': 1.5, 'price': 150.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    return original, InvoiceCorrection.query.get(resp.get_json()['id'])


def test_the_correction_records_the_right_profit_and_the_paid_one_stays(auth_headers, world):
    original, correction = _3314(auth_headers, world)
    assert correction.before['profit']['profit_gold'] == pytest.approx(0.136)
    # its price at the time: 330 / (3.3 - 0.136); the right weight 1.8 + 1.5 x 18/21 loses at it --
    # the loss is kept, below nothing (POINTS-DEFICIT-1); it was recorded as nothing. Whether it
    # costs points is the settings' day's (none here: the next test's -1.36 stands).
    assert correction.after['profit']['profit_gold'] == pytest.approx(-0.078, abs=0.001)
    assert Invoice.query.get(original.id).profit_gold == pytest.approx(0.136), 'as paid'


def test_the_engine_takes_the_difference_in_the_corrections_period(auth_headers, world):
    from points.engine import compute_invoices_points, corrections_against
    original, correction = _3314(auth_headers, world)
    now = datetime.now()
    found = corrections_against(lambda o: o.id == original.id, now - timedelta(days=1), now + timedelta(days=1))
    assert [c.correction_id for c in found] == [correction.id]
    assert compute_invoices_points(found, **GOLD) == pytest.approx(-1.36)
    assert compute_invoices_points([original] + found, **GOLD) == pytest.approx(0.0)
    assert not corrections_against(lambda o: o.id == original.id, now + timedelta(days=2), now + timedelta(days=3))


def test_the_race_takes_them_from_the_one_who_bought(auth_headers, world):
    from metrics.points_metric import PointsMetric
    from points.engine import corrections_against
    original, _ = _3314(auth_headers, world)
    original.employee_id = world['holder'].id
    db.session.flush()
    now = datetime.now()
    found = corrections_against(lambda o: o.id == original.id, now - timedelta(days=1), now + timedelta(days=1))
    metric = PointsMetric(points_source='gold_weight')
    _, _, _, _, total, _, purchase = metric._group_and_score([original] + found, 10.0)
    assert total[world['holder'].id] == pytest.approx(0.0)


def test_a_mode_of_lines_reads_the_invoice_as_it_was_posted(auth_headers, world):
    """The weight sold: 2.2 g bought, corrected to 3.0 g -- its own period keeps
    2.2 g, the correction's period adds 0.8 g."""
    from points.engine import compute_invoices_points, corrections_against
    from tests.test_melting_and_renewal_go_one_way import _holds
    invoice, line = _bought(auth_headers, world, grams=2.2, price=220.0)
    resp = _correct(auth_headers, invoice['id'], {
        'line_id': line.id, 'reason': 'وزن خاطئ',
        'safe_box_id': SafeBox.query.filter_by(account_id=world['custody'].id).one().id,
        'lines': [{'karat': 21, 'weight': 3.0, 'price': 220.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    sold = dict(points_source='sold_weight', cash_amount_per_point=100.0, points_per_gram=10.0)
    original = Invoice.query.get(invoice['id'])
    assert compute_invoices_points([original], **sold) == pytest.approx(22.0), 'as posted: 2.2 g'
    now = datetime.now()
    found = corrections_against(lambda o: o.id == original.id, now - timedelta(days=1), now + timedelta(days=1))
    assert compute_invoices_points(found, **sold) == pytest.approx(8.0), 'the correction: +0.8 g'


def test_todays_race_takes_the_correction_from_the_buyer(auth_headers, world):
    import json
    from models import Settings
    from tests.test_the_race_card_adds_up import _race
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 100.0,
                                               'points_per_gram': 10.0})
    db.session.flush()
    invoice, line = _bought(auth_headers, world)
    original = Invoice.query.get(invoice['id'])
    original.profit_gold, original.employee_id = 0.136, world['holder'].id
    original.profit_cash = 0.0                # bought before it had a cash profit: scored by its grams
    original.date = datetime.now()            # bought today, corrected today: one period
    db.session.flush()

    def score():
        rows = [r for r in _race(auth_headers)['ranking'] if r['id'] == world['holder'].id]
        return int(rows[0]['score']) if rows else 0
    paid = score()
    resp = _correct(auth_headers, invoice['id'], {
        'line_id': line.id, 'reason': 'تصحيح عيار',
        'safe_box_id': SafeBox.query.filter_by(account_id=world['custody'].id).one().id,
        'lines': [{'karat': 21, 'weight': 1.8, 'price': 180.0}, {'karat': 18, 'weight': 1.5, 'price': 150.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    assert score() == paid - 1, '0.136 g x 10 a gram: its one point back, today'
