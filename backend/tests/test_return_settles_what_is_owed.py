"""A return of an invoice not wholly paid gives back what was paid (RETURN-OWED-1).

The owner (8 Oct 2026): when an invoice still owed something is returned in
full, the customer gets back what they paid, and the rest of the debt goes
with the goods. The entries already said so -- a sale return credits the
customer the whole total and the refund debits them what is given back -- but
the whole reversal refused such an invoice (invoice_not_fully_paid), a refund
was bounded only by the return's total, never by what had come in, and the
original stayed «partially paid» in the lists of what is owed after its debt
was gone.

Run:
    python -m pytest tests/test_return_settles_what_is_owed.py -v
"""
import pytest
from sqlalchemy import func

from app import app as flask_app
from models import Invoice, JournalEntry, JournalEntryLine, Settings, db
from tests.retraction_world import _payload, unposting_allowed, world  # noqa: F401 (fixture)
from tests.test_return_within_its_original import _post, _return_of


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _partial_payments(allowed):
    row = Settings.query.first()
    if row is None:
        row = Settings()
        db.session.add(row)
    row.allow_partial_invoice_payments = allowed
    db.session.flush()


def _sale_paid(headers, world, paid):
    """A posted sale of 2 g for 1,000.00 to a named customer, `paid` of it in cash."""
    _partial_payments(True)
    payload = _payload(world, 'sale_on_credit', held=False)
    payload['total_cost'] = 0.0
    payload['amount_paid'] = paid
    payload['payments'] = ([{'payment_method_id': world['pm'].id, 'amount': paid}]
                           if paid else [])
    resp = _post(headers, payload)
    assert resp.status_code == 201, resp.get_json()
    _partial_payments(False)
    return resp.get_json()


def _scrap_purchase_paid(headers, world, paid):
    _partial_payments(True)
    payload = _payload(world, 'scrap_purchase_unpaid', held=False)
    payload['amount_paid'] = paid
    payload['payments'] = [{'payment_method_id': world['pm'].id, 'amount': paid}]
    resp = _post(headers, payload)
    assert resp.status_code == 201, resp.get_json()
    _partial_payments(False)
    return resp.get_json()


def _reverse(headers, invoice_id, payments):
    return flask_app.test_client().post(f'/api/invoices/{invoice_id}/reverse',
                                        headers=headers,
                                        json={'reason': 'عيب', 'payments': payments})


def _balance(account_id):
    """The account's cash balance, debit less credit, from the ledger."""
    db.session.expire_all()
    d, c = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_debit), 0),
                             func.coalesce(func.sum(JournalEntryLine.cash_credit), 0))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntryLine.account_id == account_id,
                    JournalEntry.is_deleted.is_(False),
                    JournalEntryLine.is_deleted.is_(False))
            .one())
    return round(float(d) - float(c), 2)


def _status(invoice_id):
    db.session.expire_all()
    return db.session.get(Invoice, invoice_id).status


def test_a_sale_paid_in_part_is_reversed_refunding_what_was_paid(auth_headers, world):
    sale = _sale_paid(auth_headers, world, 600.0)

    resp = _reverse(auth_headers, sale['id'], [{'payment_method_id': world['pm'].id}])

    assert resp.status_code == 201, resp.get_json()
    ret = resp.get_json()
    assert round(float(ret['total']), 2) == 1000.0
    assert round(float(ret['amount_paid']), 2) == 600.0


def _customer_account(world):
    """The customer's account, made on its first entry."""
    db.session.refresh(world['customer'])
    return world['customer'].account_id


def test_the_customer_owes_nothing_after_it(auth_headers, world):
    sale = _sale_paid(auth_headers, world, 600.0)
    account = _customer_account(world)
    owed = _balance(account)   # 1,000 sold, 600 paid: 400 of it is this sale's

    resp = _reverse(auth_headers, sale['id'], [{'payment_method_id': world['pm'].id}])
    assert resp.status_code == 201, resp.get_json()

    assert _balance(account) == round(owed - 400.0, 2)


def test_the_original_is_no_longer_owed(auth_headers, world):
    sale = _sale_paid(auth_headers, world, 600.0)
    assert _status(sale['id']) == 'partially_paid'

    resp = _reverse(auth_headers, sale['id'], [{'payment_method_id': world['pm'].id}])
    assert resp.status_code == 201, resp.get_json()

    assert _status(sale['id']) == 'paid'


def test_more_than_was_paid_is_not_refunded(auth_headers, world):
    sale = _sale_paid(auth_headers, world, 600.0)

    resp = _reverse(auth_headers, sale['id'],
                    [{'payment_method_id': world['pm'].id, 'amount': 1000.0}])

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'refund_must_equal_paid'
    assert resp.get_json()['paid'] == 600.0


def test_a_sale_never_paid_is_reversed_refunding_nothing(auth_headers, world):
    sale = _sale_paid(auth_headers, world, 0.0)
    account = _customer_account(world)
    owed = _balance(account)

    resp = _reverse(auth_headers, sale['id'], [])

    assert resp.status_code == 201, resp.get_json()
    assert round(float(resp.get_json()['amount_paid'] or 0.0), 2) == 0.0
    assert _balance(account) == round(owed - 1000.0, 2)
    assert _status(sale['id']) == 'paid'


def test_a_manual_return_refunds_no_more_than_was_paid(auth_headers, world):
    sale = _sale_paid(auth_headers, world, 600.0)

    resp = _post(auth_headers, _return_of(world, sale, total=1000.0))

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'return_refund_exceeds_paid'
    assert resp.get_json()['refundable'] == 600.0


def test_a_scrap_purchase_paid_in_part_is_reversed_receiving_back_what_was_paid(
        auth_headers, world):
    purchase = _scrap_purchase_paid(auth_headers, world, 60.0)   # of 100
    account = _customer_account(world)
    before = _balance(account)

    resp = _reverse(auth_headers, purchase['id'], [{'payment_method_id': world['pm'].id}])

    assert resp.status_code == 201, resp.get_json()
    assert round(float(resp.get_json()['amount_paid']), 2) == 60.0
    # We owed the customer 40; the return takes that debt with the gold.
    assert _balance(account) == round(before + 40.0, 2)
    assert _status(purchase['id']) == 'paid'





def test_a_scrap_purchase_return_is_entered_on_the_customers_own_account(
        auth_headers, world):
    """Its entry was debited to the parent «customers» account while its
    refund was credited to the customer's own, leaving the customer a credit
    they never had -- the five returns on the 6 Oct copy, 37,670."""
    purchase = _scrap_purchase_paid(auth_headers, world, 100.0)
    account = _customer_account(world)
    before = _balance(account)

    resp = _reverse(auth_headers, purchase['id'], [{'payment_method_id': world['pm'].id}])

    assert resp.status_code == 201, resp.get_json()
    assert _balance(account) == before


def test_a_return_unposted_gives_its_original_its_debt_back(
        auth_headers, world, unposting_allowed):
    sale = _sale_paid(auth_headers, world, 0.0)
    resp = _reverse(auth_headers, sale['id'], [])
    assert resp.status_code == 201, resp.get_json()
    assert _status(sale['id']) == 'paid'

    unposted = flask_app.test_client().post(
        f"/api/invoices/{resp.get_json()['id']}/unpost", headers=auth_headers, json={})

    assert unposted.status_code == 200, unposted.get_json()
    assert _status(sale['id']) == 'unpaid'
