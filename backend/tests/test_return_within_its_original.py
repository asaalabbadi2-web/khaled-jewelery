"""A return can not give back more than its sale was (RETURN-LIMIT-1).

On the 6 Oct production copy all nine customer returns (4 sale returns, 5 of
scrap purchases) are whole-invoice returns at the original's exact total and
weight, one each. Nothing stopped a second return of the same sale, or a
refund typed larger than what was sold: add_invoice checked each line against
its original line (return_quantity_exceeds_original) but only within the one
request, and never the refund. The owner (8 Oct 2026): a return is bounded by
its original -- what is refunded no more than what was sold, and the weight
returned, across all its returns, no more than the weight sold.

Run:
    python -m pytest tests/test_return_within_its_original.py -v
"""
import pytest

from app import app as flask_app
from models import Settings, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def _paid_sale(headers, world):
    """A posted sale of 2 g for 1,000.00, paid in cash."""
    payload = _payload(world, 'sale_on_credit', held=False)
    payload['total_cost'] = 0.0
    payload['amount_paid'] = payload['total']
    payload['payments'] = [{'payment_method_id': world['pm'].id, 'amount': payload['total']}]
    resp = _post(headers, payload)
    assert resp.status_code == 201, resp.get_json()
    return resp.get_json()


def _return_of(world, sale, *, total, weight=2.0):
    item = sale['items'][0]
    return {
        'invoice_type': 'مرتجع بيع', 'customer_id': world['customer'].id,
        'original_invoice_id': sale['id'], 'gold_type': 'new',
        'branch_id': sale.get('branch_id'),
        'date': sale['date'], 'total': total, 'total_weight': weight, 'total_tax': 0.0,
        'amount_paid': total,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': total}],
        'items': [{'name': item['name'], 'karat': item['karat'], 'weight': weight,
                   'quantity': 1, 'price': total, 'net': total, 'wage': 0, 'tax': 0,
                   'original_invoice_item_id': item['id']}],
    }


def test_a_whole_return_at_the_sale_total_is_taken(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    resp = _post(auth_headers, _return_of(world, sale, total=1000.0))
    assert resp.status_code == 201, resp.get_json()


def test_a_refund_larger_than_the_sale_is_refused(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    resp = _post(auth_headers, _return_of(world, sale, total=1500.0))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'return_refund_exceeds_original'


def test_a_second_whole_return_of_the_same_sale_is_refused(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    assert _post(auth_headers, _return_of(world, sale, total=1000.0)).status_code == 201
    resp = _post(auth_headers, _return_of(world, sale, total=1000.0))
    assert resp.status_code == 400
    assert resp.get_json()['error'] in ('return_weight_exceeds_original',
                                        'return_refund_exceeds_original')


def test_two_partial_returns_that_fit_are_taken(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    first = _post(auth_headers, _return_of(world, sale, total=500.0, weight=1.0))
    second = _post(auth_headers, _return_of(world, sale, total=500.0, weight=1.0))
    assert first.status_code == 201, first.get_json()
    assert second.status_code == 201, second.get_json()
    third = _post(auth_headers, _return_of(world, sale, total=100.0, weight=0.2))
    assert third.status_code == 400
