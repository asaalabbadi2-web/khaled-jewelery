"""A returned line's amount is typed, bounded by the line (the owner, 11 Nov 2026).

«الوزن والمبلغ المرتجع يكتب يدويا فلا يحكم مبلغ السطر الاصلي سعر المرتجع».
A shop often gives back less than it sold for -- the wage kept, the gold at
today's price -- so what a line gives back is the employee's to type, with
its weight. The screen took the smaller of the weight's and the count's
shares of the line, and sent the weight typed: 1 of 5 bangles by its count
gave back 3,400 and took the five's 35.6 g into the stock.

The law now: every returned line has its amount; of a line, across its
returns, no more than it sold for («نعم»); a return's total is its lines';
and what is paid back no more than the return is worth -- nor than was paid
(RETURN-OWED-1). Its cost and its points follow its weight; its VAT, its
original's as posted (ADR-043). A line's value is its price, or its share of
its invoice's total where its lines do not add up to it (110 sales of
Jan-Mar 2026).

Run:
    python -m pytest tests/test_return_amounts_typed.py -v
"""
import pytest

from app import app as flask_app
from models import Invoice, InvoiceItem, Settings, db
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_return_line_remaining import _line, _post, _return, _sale


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _refused(resp, code):
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == code, body
    return body


def test_a_returned_line_has_its_amount(auth_headers, world):
    sale = _sale(auth_headers, world)
    _refused(_post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 0.0)])), 'return_line_unpriced')


def test_a_line_comes_back_for_less_than_it_sold_for(auth_headers, world):
    sale = _sale(auth_headers, world)
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 700.0)]))
    assert resp.status_code == 201, resp.get_json()
    ret = db.session.get(Invoice, resp.get_json()['id'])
    assert round(ret.total, 2) == 700.0 and round(ret.total_weight, 3) == 2.0


def test_of_a_line_no_more_than_it_sold_for_across_its_returns(auth_headers, world):
    sale = _sale(auth_headers, world)
    assert _post(auth_headers, _return(world, sale, [('بنجرة', 4.0, 2, 3000.0)])).status_code == 201
    body = _refused(_post(auth_headers, _return(world, sale, [('بنجرة', 4.0, 2, 2500.0)])),
                    'return_line_amount_exceeds_original')
    assert body['line'] == 'بنجرة' and body['remaining_amount'] == 2000.0


def test_a_return_s_total_is_its_lines(auth_headers, world):
    sale = _sale(auth_headers, world)
    payload = _return(world, sale, [('خاتم', 2.0, 1, 700.0)])
    payload['total'] = 1000.0
    _refused(_post(auth_headers, payload), 'return_total_not_its_lines')


def test_no_more_is_paid_back_than_the_return_is_worth(auth_headers, world):
    sale = _sale(auth_headers, world)
    payload = _return(world, sale, [('خاتم', 2.0, 1, 700.0)])
    payload['payments'] = [{'payment_method_id': world['pm'].id, 'amount': 900.0}]
    payload['amount_paid'] = 900.0
    _refused(_post(auth_headers, payload), 'return_refund_exceeds_return')


def test_a_sale_never_paid_comes_back_paying_nothing_back(auth_headers, world):
    row = Settings.query.first() or Settings()
    row.allow_partial_invoice_payments = True
    db.session.add(row)
    db.session.flush()
    sale = _sale(auth_headers, world)
    original = db.session.get(Invoice, sale['id'])
    original.amount_paid = 0.0
    db.session.flush()
    payload = _return(world, sale, [('خاتم', 2.0, 1, 1000.0)])
    payload['payments'], payload['amount_paid'] = [], 0.0
    resp = _post(auth_headers, payload)
    assert resp.status_code == 201, resp.get_json()
    assert round(float(resp.get_json()['amount_paid'] or 0.0), 2) == 0.0


def test_a_line_s_value_is_its_share_where_its_lines_do_not_add_up(auth_headers, world):
    """Jan-Mar 2026: lines of 2,540 on a sale of 12,700 -- a line is worth its share."""
    sale = _sale(auth_headers, world)
    for item in InvoiceItem.query.filter_by(invoice_id=sale['id']).all():
        item.price, item.net = item.price / 5, item.net / 5   # by price nor by net they add up          # the lines add up to a fifth of the total
    db.session.flush()
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert resp.status_code == 201, resp.get_json()


def test_a_whole_reversal_carries_its_lines_values(auth_headers, world):
    sale = _sale(auth_headers, world)
    for item in InvoiceItem.query.filter_by(invoice_id=sale['id']).all():
        item.price, item.net = item.price / 5, item.net / 5   # by price nor by net they add up
    db.session.flush()
    from flask import g
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f"/api/invoices/{sale['id']}/reverse", headers=auth_headers, json={
        'reason': 'عيب', 'payments': [{'payment_method_id': world['pm'].id}]})
    assert resp.status_code == 201, resp.get_json()
    lines = InvoiceItem.query.filter_by(invoice_id=resp.get_json()['id']).all()
    assert round(sum(l.price for l in lines), 2) == 26000.0
    assert {l.name: round(l.price, 2) for l in lines}['خاتم'] == 1000.0
    assert _line(sale, 'خاتم')['id'] in {l.original_invoice_item_id for l in lines}


# ── what remains, said to the screen (GET /invoices/<id>/return-lines) ───────

def _remaining(headers, sale_id):
    from flask import g
    g.pop('current_user', None)
    resp = flask_app.test_client().get(f'/api/invoices/{sale_id}/return-lines', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_the_screen_is_told_what_remains_of_each_line(auth_headers, world):
    sale = _sale(auth_headers, world)
    assert _post(auth_headers, _return(world, sale, [('بنجرة', 4.0, 2, 1500.0)])).status_code == 201
    body = _remaining(auth_headers, sale['id'])
    lines = {l['name']: l for l in body['lines']}
    assert lines['بنجرة']['sold_grams'] == 10.0 and lines['بنجرة']['sold_amount'] == 5000.0
    assert lines['بنجرة']['remaining_grams'] == 6.0 and lines['بنجرة']['remaining_amount'] == 3500.0
    assert lines['خاتم']['remaining_grams'] == 2.0 and lines['خاتم']['remaining_amount'] == 1000.0
    assert body['returned_before'] is True
    assert body['refundable'] == 26000.0 - 1500.0


def test_a_seller_is_not_told_it(auth_headers, world):
    from tests.test_returns_are_the_accountants import _headers_for
    sale = _sale(auth_headers, world)
    from flask import g
    g.pop('current_user', None)
    resp = flask_app.test_client().get(f"/api/invoices/{sale['id']}/return-lines", headers=_headers_for('employee'))
    assert resp.status_code == 403
