"""A sale return cancels (or shrinks) its sale's weight-closing order (WCO-RETURN-1).

On the 6 Oct production copy the four sale returns (all April) left their
sales' weight-closing orders «cancelled»: the gold came back, nothing is left
to close. Since the routes moved (July), the block that does it raised
NameError -- WeightClosingOrder was not imported in routes/invoices.py -- and a
try/except printed it and went on: a returned sale's order stayed «open», to be
closed later against gold that is back in the shop. No sale was returned since,
so no row is wrong yet.

Run:
    python -m pytest tests/test_sale_return_closes_its_weight_order.py -v
"""
import pytest

from app import app as flask_app
from models import WeightClosingOrder, db
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_return_within_its_original import _paid_sale, _post, _return_of


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _order_of(invoice_id):
    db.session.expire_all()
    return WeightClosingOrder.query.filter_by(invoice_id=invoice_id).first()


def test_a_sale_has_an_order_to_close(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    order = _order_of(sale['id'])
    assert order is not None
    assert order.status == 'open'


def test_a_whole_return_cancels_it(auth_headers, world):
    sale = _paid_sale(auth_headers, world)

    ret = _post(auth_headers, _return_of(world, sale, total=1000.0))

    assert ret.status_code == 201, ret.get_json()
    assert _order_of(sale['id']).status == 'cancelled'


def test_a_half_return_halves_what_is_left_to_close(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    before = float(_order_of(sale['id']).total_weight_main_karat or 0.0)

    ret = _post(auth_headers, _return_of(world, sale, total=500.0, weight=1.0))

    assert ret.status_code == 201, ret.get_json()
    after = _order_of(sale['id'])
    assert after.status == 'open'
    assert round(float(after.total_weight_main_karat), 3) == round(before / 2, 3)


def test_a_return_of_a_closed_sale_reverses_what_was_closed(auth_headers, world):
    """The gold came back after it was closed against scrap bought: the closing
    is reversed by an execution of its own (negative weight), not left as
    closed against gold that is in the shop again."""
    from models import WeightClosingExecution
    sale = _paid_sale(auth_headers, world)
    order = _order_of(sale['id'])
    total = float(order.total_weight_main_karat or 0.0)
    db.session.add(WeightClosingExecution(order_id=order.id, execution_type='purchase_scrap',
                                          weight_main_karat=total, price_per_gram=400.0))
    order.executed_weight_main_karat = total
    order.remaining_weight_main_karat = 0.0
    order.status = 'closed'
    db.session.flush()

    ret = _post(auth_headers, _return_of(world, sale, total=1000.0))

    assert ret.status_code == 201, ret.get_json()
    after = _order_of(sale['id'])
    assert after.status == 'cancelled'
    reversal = WeightClosingExecution.query.filter_by(
        order_id=order.id, execution_type='sale_return_reversal').all()
    assert len(reversal) == 1
    assert round(float(reversal[0].weight_main_karat), 3) == round(-total, 3)
