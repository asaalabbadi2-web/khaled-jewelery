"""A supplier purchase's shown status is its running account's (REPORTS ت3-2ج, ADR-083).

The owner, 4 Nov 2026 («تحل محل الحالة الظاهرة»): a voucher pays the
supplier's account, not an invoice, so Invoice.status -- explicit payments
only -- read «غير مدفوعة» for 94 purchases the running account had paid. The
invoices' list now says, for each posted supplier purchase, the reading's
state and why: the row (running_account), the paid / remaining filter, the
order by status, and the tab's paid and unpaid amounts. Invoice.status stays,
the record of explicit payments; it is not what a purchase shows. A posted
purchase the supplier's ledger does not hold says so: not on its account.

Run:
    python -m pytest tests/test_purchase_status_from_running_account.py -v
"""
import datetime as dt
import uuid
from urllib.parse import quote

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, Invoice, db
from tests.test_supplier_running_account import _post, _supplier, _voucher

D = dt.datetime


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _headers():
    user = AppUser(username=f'manager-{uuid.uuid4().hex[:6]}', role='manager', is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _get(path):
    headers = _headers()
    g.pop('current_user', None)   # one app context for the module; each request in production has its own
    return flask_app.test_client().get(path, headers=headers)


def _purchase(supplier, day):
    inv = Invoice(invoice_type='شراء', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=D(2043, 5, day),
                  supplier_id=supplier.id, total=0.0, is_posted=True, status='unpaid')
    db.session.add(inv)
    db.session.flush()
    return inv


@pytest.fixture
def books():
    supplier, weight = _supplier()
    supplier.name = f'مورد الحالة {uuid.uuid4().hex[:6]}'
    paid, part, outside = _purchase(supplier, 1), _purchase(supplier, 2), _purchase(supplier, 3)
    _post(supplier, weight, 1, 10.0, 'invoice', paid.id)
    _post(supplier, weight, 2, 5.0, 'invoice', part.id)
    v = _voucher(4)
    _post(supplier, weight, 4, -12.0, 'voucher', v.id)                # the oldest: paid closed, part 3 left
    db.session.flush()
    return {'supplier': supplier, 'paid': paid, 'part': part, 'outside': outside}


def test_the_reading_s_state_for_each_posted_purchase(books):
    from services.supplier_running_account import purchase_states
    states = purchase_states([books['paid'].id, books['part'].id, books['outside'].id])
    assert states[books['paid'].id]['state'] == 'paid'
    assert states[books['paid'].id]['basis'] == 'running_account'
    assert states[books['part'].id]['state'] == 'partial'
    assert states[books['outside'].id]['state'] == 'not_on_account'


def _listed(books, status=None):
    query = f"/api/invoices?per_page=500&invoice_group=supplier_purchase&search={quote(books['supplier'].name)}"
    if status:
        query += f'&status={status}'
    body = _get(query).get_json()
    return {i['id']: i for i in body['invoices']}, body


def test_the_list_says_the_reading_on_each_row(books):
    rows, _ = _listed(books)
    assert rows[books['paid'].id]['running_account']['state'] == 'paid'
    assert rows[books['paid'].id]['status'] == 'unpaid', 'the stored record is not rewritten'
    assert rows[books['outside'].id]['running_account']['state'] == 'not_on_account'


def test_paid_and_remaining_are_the_reading_s(books):
    paid, _ = _listed(books, 'paid')
    remaining, _ = _listed(books, 'remaining')
    assert books['paid'].id in paid and books['paid'].id not in remaining
    assert books['part'].id in remaining and books['part'].id not in paid


def test_the_single_invoice_says_it_too(books):
    body = _get(f"/api/invoices/{books['part'].id}").get_json()
    assert body['running_account']['state'] == 'partial'







def test_the_tab_s_amounts_are_the_running_account_s(books):
    """A purchase's cash debt, as its running account closed it."""
    from models import JournalEntry
    from dual_system_helpers import create_dual_journal_entry
    supplier = books['supplier']
    entry = JournalEntry(date=D(2043, 5, 5, 12), description='جاري', entry_type='عادي', is_posted=True,
                         created_by='t', reference_type='invoice', reference_id=books['outside'].id)
    db.session.add(entry)
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=supplier.account_id, supplier_id=supplier.id,
                              apply_golden_rule=False, cash_credit=900.0)
    v = _voucher(6)
    paid = JournalEntry(date=D(2043, 5, 6, 12), description='جاري', entry_type='عادي', is_posted=True,
                        created_by='t', reference_type='voucher', reference_id=v.id)
    db.session.add(paid)
    db.session.flush()
    v.journal_entry_id = paid.id
    create_dual_journal_entry(journal_entry_id=paid.id, account_id=supplier.account_id, supplier_id=supplier.id,
                              apply_golden_rule=False, cash_debit=600.0)
    db.session.flush()
    stray = _purchase(supplier, 7)
    stray.total = 787128.39                                         # not on the account: no debt there
    db.session.flush()
    _, body = _listed(books)
    summary = body['meta']['tab_summary']['supplier_purchase']
    assert summary['unpaid_amount'] == pytest.approx(300.0)
    assert summary['paid_amount'] == pytest.approx(600.0)


def test_the_order_by_status_is_the_shown_one(books):
    g.pop('current_user', None)
    rows = _get(f"/api/invoices?per_page=500&invoice_group=supplier_purchase&sort_by=status&sort_order=asc"
                f"&search={quote(books['supplier'].name)}").get_json()['invoices']
    order = [r['id'] for r in rows]
    # not_on_account < paid < partially_paid, by the shown word; stored they are all «unpaid»
    assert order == [books['outside'].id, books['paid'].id, books['part'].id]
