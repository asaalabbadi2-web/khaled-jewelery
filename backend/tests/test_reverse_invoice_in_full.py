"""A sale or a scrap purchase is reversed in full by the server (RETURN-FULL-1).

The owner (8 Oct 2026): all nine customer returns on the 6 Oct copy are whole
returns at the original's exact total, yet the screen was a five-step wizard
in which the refund was a number the clerk typed. A whole return is now one
call that names the original: the server reads its lines, weights, tax and
total and builds the return from them -- the screen sends only the reason and
how it is refunded. The entries are the ones the manual whole return makes.

Run:
    python -m pytest tests/test_reverse_invoice_in_full.py -v
"""
import pytest
from sqlalchemy import func

from app import app as flask_app
from models import Invoice, JournalEntry, JournalEntryLine, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)
from tests.test_return_within_its_original import _paid_sale, _post, _return_of


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _reverse(headers, invoice_id, body):
    return flask_app.test_client().post(f'/api/invoices/{invoice_id}/reverse',
                                        headers=headers, json=body)


def _entries(invoice_id):
    """(account, cash debit, cash credit) of the invoice's entries, sorted."""
    db.session.expire_all()
    rows = (db.session.query(JournalEntryLine.account_id,
                             func.coalesce(func.sum(JournalEntryLine.cash_debit), 0),
                             func.coalesce(func.sum(JournalEntryLine.cash_credit), 0))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntry.reference_type == 'invoice',
                    JournalEntry.reference_id == invoice_id,
                    JournalEntry.is_deleted.is_(False),
                    JournalEntryLine.is_deleted.is_(False))
            .group_by(JournalEntryLine.account_id).all())
    return sorted((a, round(float(d), 2), round(float(c), 2)) for a, d, c in rows)


def test_a_sale_is_reversed_in_one_call(auth_headers, world):
    sale = _paid_sale(auth_headers, world)

    resp = _reverse(auth_headers, sale['id'],
                    {'reason': 'عيب في الصنع',
                     'payments': [{'payment_method_id': world['pm'].id}]})

    assert resp.status_code == 201, resp.get_json()
    ret = resp.get_json()
    assert ret['invoice_type'] == 'مرتجع بيع'
    assert ret['original_invoice_id'] == sale['id']
    assert round(float(ret['total']), 2) == 1000.0


def test_its_entries_are_the_manual_whole_returns(auth_headers, world):
    manual_sale = _paid_sale(auth_headers, world)
    manual = _post(auth_headers, _return_of(world, manual_sale, total=1000.0))
    assert manual.status_code == 201, manual.get_json()

    sale = _paid_sale(auth_headers, world)
    resp = _reverse(auth_headers, sale['id'],
                    {'reason': 'x', 'payments': [{'payment_method_id': world['pm'].id}]})
    assert resp.status_code == 201, resp.get_json()

    assert _entries(resp.get_json()['id']) == _entries(manual.get_json()['id'])


def test_the_amount_is_the_originals_not_the_clerks(auth_headers, world):
    sale = _paid_sale(auth_headers, world)

    resp = _reverse(auth_headers, sale['id'],
                    {'reason': 'x',
                     'payments': [{'payment_method_id': world['pm'].id, 'amount': 1500.0}]})

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'refund_must_equal_paid'


def test_a_refund_split_in_two_that_adds_up_is_taken(auth_headers, world):
    sale = _paid_sale(auth_headers, world)

    resp = _reverse(auth_headers, sale['id'],
                    {'reason': 'x',
                     'payments': [{'payment_method_id': world['pm'].id, 'amount': 400.0},
                                  {'payment_method_id': world['pm'].id, 'amount': 600.0}]})

    assert resp.status_code == 201, resp.get_json()


def test_a_reason_is_required(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    resp = _reverse(auth_headers, sale['id'],
                    {'reason': '  ', 'payments': [{'payment_method_id': world['pm'].id}]})
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'reason_required'


def test_a_sale_already_returned_is_not_reversed_again(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    body = {'reason': 'x', 'payments': [{'payment_method_id': world['pm'].id}]}
    assert _reverse(auth_headers, sale['id'], body).status_code == 201

    resp = _reverse(auth_headers, sale['id'], body)

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'already_returned'


def test_a_method_is_required(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    resp = _reverse(auth_headers, sale['id'], {'reason': 'x', 'payments': []})
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'payment_required'


def test_an_unposted_invoice_is_edited_or_deleted_not_reversed(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    inv = db.session.get(Invoice, sale['id'])
    inv.is_posted = False
    db.session.flush()

    resp = _reverse(auth_headers, sale['id'],
                    {'reason': 'x', 'payments': [{'payment_method_id': world['pm'].id}]})

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invoice_not_posted'


def test_an_invoice_that_is_not_reversible_this_way(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    inv = db.session.get(Invoice, sale['id'])
    inv.invoice_type = 'شراء'   # a supplier purchase is returned on its own screen
    db.session.flush()

    resp = _reverse(auth_headers, sale['id'],
                    {'reason': 'x', 'payments': [{'payment_method_id': world['pm'].id}]})

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'reverse_not_supported'


def test_a_missing_invoice_is_not_found(auth_headers, world):
    resp = _reverse(auth_headers, 99999999,
                    {'reason': 'x', 'payments': [{'payment_method_id': world['pm'].id}]})
    assert resp.status_code == 404


def test_a_scrap_purchase_from_a_customer_is_reversed_the_same_way(auth_headers, world):
    purchase = _post(auth_headers, _payload(world, 'scrap_purchase_paid', held=False))
    assert purchase.status_code == 201, purchase.get_json()
    purchase = purchase.get_json()

    resp = _reverse(auth_headers, purchase['id'],
                    {'reason': 'استرجاع', 'payments': [{'payment_method_id': world['pm'].id}]})

    assert resp.status_code == 201, resp.get_json()
    ret = resp.get_json()
    assert ret['invoice_type'] == 'مرتجع شراء'
    assert ret['original_invoice_id'] == purchase['id']
    assert round(float(ret['total']), 2) == round(float(purchase['total']), 2)



# An invoice paid only in part is reversed refunding what was paid
# (RETURN-OWED-1): tests/test_return_settles_what_is_owed.py.
