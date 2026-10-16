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


# ── OFFICE-COGS-1: the return reverses what the execution posted, no more ──

def _executed(order, *, execution_type, entry_lines):
    """Close *order* by one execution whose entry is *entry_lines* [(account_id, debit, credit)]."""
    import uuid
    from models import JournalEntry, JournalEntryLine, WeightClosingExecution
    from datetime import datetime
    je = JournalEntry(entry_number=f'JE-WCO-{uuid.uuid4().hex[:8]}', date=datetime.now(),
                      description='تنفيذ تسكير', entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account_id, debit, credit in entry_lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account_id,
                                        cash_debit=debit, cash_credit=credit, description='تنفيذ'))
    total = float(order.total_weight_main_karat or 0.0)
    db.session.add(WeightClosingExecution(order_id=order.id, execution_type=execution_type,
                                          weight_main_karat=total, price_per_gram=400.0,
                                          journal_entry_id=je.id))
    order.executed_weight_main_karat = total
    order.remaining_weight_main_karat = 0.0
    order.status = 'closed'
    db.session.flush()


def _return_lines_on(return_id, account_id):
    from models import JournalEntry, JournalEntryLine
    entries = [je.id for je in JournalEntry.query.filter_by(reference_type='invoice', reference_id=return_id)]
    return [ln for ln in JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries or [-1]),
                                                       JournalEntryLine.account_id == account_id)]


def _cost_of_sales():
    from accounting.mappings import require_account
    return require_account('افتراضي', 'gold_cost_of_sales')


def _other_account():
    import uuid
    from models import Account
    account = Account(account_number=f'96{uuid.uuid4().int % 10**6:06d}', name='طرف تنفيذ', type='Asset')
    db.session.add(account)
    db.session.flush()
    return account.id


def test_an_office_execution_is_a_purchase_and_its_sale_s_return_reverses_no_cost(auth_headers, world):
    """The office's execution bought the gold (its entry: purchases / the office);
    no cost of sales was posted. The return credited cost of sales anyway --
    a credit on 521 never debited (the owner, 16 Oct 2026: nothing of an office
    execution is reversed)."""
    sale = _paid_sale(auth_headers, world)
    purchases, office = _other_account(), _other_account()
    _executed(_order_of(sale['id']), execution_type='office_reservation',
              entry_lines=[(purchases, 457.14, 0.0), (office, 0.0, 457.14)])

    ret = _post(auth_headers, _return_of(world, sale, total=1000.0))

    assert ret.status_code == 201, ret.get_json()
    assert _return_lines_on(ret.get_json()['id'], _cost_of_sales()) == []
    assert _order_of(sale['id']).status == 'cancelled'


def test_a_closing_that_posted_its_cost_has_it_reversed(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    _executed(_order_of(sale['id']), execution_type='purchase_scrap',
              entry_lines=[(_cost_of_sales(), 457.14, 0.0), (_other_account(), 0.0, 457.14)])

    ret = _post(auth_headers, _return_of(world, sale, total=1000.0))

    assert ret.status_code == 201, ret.get_json()
    credited = sum(float(ln.cash_credit or 0) for ln in _return_lines_on(ret.get_json()['id'], _cost_of_sales()))
    assert credited > 0
