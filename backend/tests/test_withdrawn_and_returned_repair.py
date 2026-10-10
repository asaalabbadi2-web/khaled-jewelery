"""The repair of what withdrawn sales and sale returns left behind (10 Oct 2026).

services/repair/withdrawn_and_returned.py: rejected sales' open closing orders
cancelled; uncategorised sale-return lines given their original's category,
the inventory ledger reposted under it and the category weight written. Dry
run writes nothing; a second run finds nothing; an order with gold closed
against it is refused. No journal entry is written.

Run:
    python -m pytest tests/test_withdrawn_and_returned_repair.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import (CategoryWeightMovement, InventoryLedger, InvoiceItem, JournalEntry,
                    WeightClosingExecution, WeightClosingOrder, db)
from services.repair.withdrawn_and_returned import NotAsMeasured, run_package
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_return_within_its_original import _post, _return_of
from tests.test_withdrawn_sale_and_its_return import _categorised_sale, _category, _rejected_sale


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


NOW = datetime(2026, 10, 10, 12, 0)


def _left_open(sale_id):
    """As 2821, 3123 and 3303 were left before rejecting cancelled the order."""
    order = WeightClosingOrder.query.filter_by(invoice_id=sale_id).first()
    order.status = 'open'
    order.remaining_weight_main_karat = order.total_weight_main_karat
    db.session.flush()
    return order


def _saved_uncategorised(ret_id):
    """As every sale return until 10 Oct was saved: no category anywhere."""
    for line in InvoiceItem.query.filter_by(invoice_id=ret_id):
        line.category_id = None
    for row in InventoryLedger.query.filter_by(source_type='invoice', source_id=ret_id):
        row.category_id = None
    CategoryWeightMovement.query.filter_by(invoice_id=ret_id).delete()
    db.session.flush()


def test_it_cancels_the_orders_and_categorises_the_returns(auth_headers, world):
    rejected = _rejected_sale(auth_headers, world)
    _left_open(rejected['id'])
    cat = _category()
    sale = _categorised_sale(auth_headers, world, cat)
    ret = _post(auth_headers, _return_of(world, sale, total=1000.0)).get_json()
    _saved_uncategorised(ret['id'])
    entries = JournalEntry.query.count()

    dry = run_package(by='t', now=NOW, dry_run=True)
    assert rejected['id'] in {o['invoice_id'] for o in dry['closing_orders']['orders']}
    assert ret['id'] in {r['return_id'] for r in dry['return_categories']['returns']}
    db.session.expire_all()
    assert WeightClosingOrder.query.filter_by(invoice_id=rejected['id']).first().status == 'open', 'dry run writes nothing'

    run_package(by='t', now=NOW, dry_run=False)

    db.session.expire_all()
    assert WeightClosingOrder.query.filter_by(invoice_id=rejected['id']).first().status == 'cancelled'
    assert [l.category_id for l in InvoiceItem.query.filter_by(invoice_id=ret['id'])] == [cat.id]
    assert [(m.category_id, m.weight_delta_grams) for m in CategoryWeightMovement.query.filter_by(invoice_id=ret['id'])] \
        == [(cat.id, 2.0)]
    by_bucket = {}
    for row in InventoryLedger.query.filter_by(source_type='invoice', source_id=ret['id']):
        by_bucket[row.category_id] = round(by_bucket.get(row.category_id, 0.0) + row.weight_delta, 6)
    assert by_bucket == {None: 0.0, cat.id: 2.0}, 'the no-category bucket nets out; the category has it'
    assert JournalEntry.query.count() == entries, 'no entry is written'

    again = run_package(by='t', now=NOW, dry_run=True)
    assert rejected['id'] not in {o['invoice_id'] for o in again['closing_orders']['orders']}
    assert ret['id'] not in {r['return_id'] for r in again['return_categories']['returns']}


def test_an_order_with_gold_closed_against_it_is_refused(auth_headers, world):
    rejected = _rejected_sale(auth_headers, world)
    order = _left_open(rejected['id'])
    db.session.add(WeightClosingExecution(order_id=order.id, execution_type='purchase_scrap',
                                          weight_main_karat=0.5, price_per_gram=400.0))
    db.session.flush()
    with pytest.raises(NotAsMeasured):
        run_package(by='t', now=NOW, dry_run=True, only=['closing_orders'])


def test_it_gives_each_sale_return_its_sales_cost(auth_headers, world):
    from models import Invoice
    sale = _categorised_sale(auth_headers, world, _category())
    db.session.get(Invoice, sale['id']).total_cost = 925.23
    db.session.flush()
    ret = _post(auth_headers, _return_of(world, sale, total=1000.0)).get_json()
    db.session.get(Invoice, ret['id']).total_cost = 1000.0    # as every return was saved
    db.session.flush()

    plan = run_package(by='t', now=NOW, dry_run=False, only=['return_costs'])

    assert {(r['return_id'], r['saved_cost'], r['cost']) for r in plan['return_costs']['returns']} >= {
        (ret['id'], 1000.0, 925.23)}
    db.session.expire_all()
    assert db.session.get(Invoice, ret['id']).total_cost == pytest.approx(925.23)
    again = run_package(by='t', now=NOW, dry_run=True, only=['return_costs'])
    assert ret['id'] not in {r['return_id'] for r in again['return_costs']['returns']}
