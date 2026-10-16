"""A sale opens no stored weight-closing order, and its return adjusts none
(ADR-048 phase 3a).

The riyals a sale waits on to become gold are derived from the posted books
(services/weight_position): the return takes its share off the sale there. The
stored orders and executions the old engine kept are no longer written; the
return used to shrink or cancel its sale's order and, where an execution had
posted cost of sales, credit it back (WCO-RETURN-1, OFFICE-COGS-1). On the
15 Oct production copy every execution is an office reservation's, none with a
line on cost of sales, so no reversal was ever owed.

Run:
    python -m pytest tests/test_a_sale_opens_no_stored_weight_order.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import JournalEntry, JournalEntryLine, WeightClosingExecution, WeightClosingOrder, db
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


def _cost_of_sales():
    from accounting.mappings import require_account
    return require_account('افتراضي', 'gold_cost_of_sales')


def _return_lines_on(return_id, account_id):
    entries = [je.id for je in JournalEntry.query.filter_by(reference_type='invoice', reference_id=return_id)]
    return JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries or [-1]),
                                         JournalEntryLine.account_id == account_id).all()


def test_a_sale_opens_no_stored_order(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    assert _order_of(sale['id']) is None


def test_a_return_of_a_sale_closed_by_the_old_engine_touches_neither_its_order_nor_cost_of_sales(
        auth_headers, world):
    """A legacy order closed by an execution that posted cost of sales: the
    return leaves both as they are -- the position reads the return itself."""
    sale = _paid_sale(auth_headers, world)
    je = JournalEntry(entry_number=f'JE-WCO-{uuid.uuid4().hex[:8]}', date=datetime.now(),
                      description='تنفيذ تسكير', entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=_cost_of_sales(),
                                    cash_debit=457.14, cash_credit=0.0, description='تنفيذ'))
    order = _order_of(sale['id']) or WeightClosingOrder(       # the old code opened one itself
        invoice_id=sale['id'], order_number=f'WCO-{uuid.uuid4().hex[:8]}', main_karat=21)
    order.status, order.close_price_per_gram = 'closed', 400.0
    order.total_weight_main_karat, order.executed_weight_main_karat, order.remaining_weight_main_karat = 2.0, 2.0, 0.0
    db.session.add(order)
    db.session.flush()
    db.session.add(WeightClosingExecution(order_id=order.id, execution_type='purchase_scrap',
                                          weight_main_karat=2.0, price_per_gram=400.0,
                                          journal_entry_id=je.id))
    db.session.flush()
    executions = WeightClosingExecution.query.filter_by(order_id=order.id).count()

    ret = _post(auth_headers, _return_of(world, sale, total=1000.0))

    assert ret.status_code == 201, ret.get_json()
    assert _return_lines_on(ret.get_json()['id'], _cost_of_sales()) == []
    after = _order_of(sale['id'])
    assert after.status == 'closed'
    assert float(after.total_weight_main_karat) == 2.0
    assert WeightClosingExecution.query.filter_by(order_id=order.id).count() == executions
