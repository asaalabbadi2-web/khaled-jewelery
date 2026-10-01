"""Approving an invoice is one posting, whichever button is pressed (APPROVE-001).

An invoice saved behind an approval gate (below cost, large discount, above
the live price) is left as invoice 3158 was on 29 Sep 2026: the invoice
unposted, its own journal entry unposted, its cash payment recorded with no
entry and no safe-box row, and a critical 'invoice_approval' alert in the bell.

Three routes approve it, and they did three different things:
- POST /api/invoices/post/<id>      («✓ ترحيل», المعلّقات): posted the entry,
  created the payment entry -- complete, but left the alert open.
- POST /api/invoices/approve/<id>   («اعتماد وترحيل», the bell): created the
  payment entry and posted the invoice but NEVER its own entry -- the cash
  customer was credited 4,150 with no sale against it (rehearsed on the copy).
- POST /api/invoices/<id>/approve   (API only): posted the entry, created NO
  payment entry -- the cash never reached the safe box.
- POST /api/invoices/post-batch      («إدارة الترحيل»): skipped the karat-difference
  and 24k-settlement entries (POST-001 alive in this path alone).

Now each runs the same posting and must leave the same, complete result: the
invoice and every one of its entries posted, the payment's entry and safe-box
row created, the customer netted to zero, the alert closed.

Run:
    python -m pytest tests/test_invoice_approval_is_one_posting.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (Account, Customer, Invoice, InvoicePayment, JournalEntry, JournalEntryLine,
                    PaymentMethod, SafeBox, SafeBoxTransaction, SystemAlert, db)
from tests.cleanup import purge  # UNPOST-001 U3: cleanup of posted rows is a purge

ROUTES = {
    'post («✓ ترحيل»)': '/api/invoices/post/{id}',
    'approve («اعتماد وترحيل»)': '/api/invoices/approve/{id}',
    'approve (API)': '/api/invoices/{id}/approve',
    'post batch («إدارة الترحيل»)': '/api/invoices/post-batch',
}


def _call(client, route, invoice_id, headers):
    if route.endswith('post-batch'):
        return client.post(route, headers=headers, json={'invoice_ids': [invoice_id]})
    return client.post(route.format(id=invoice_id), headers=headers, json={})


def _uid():
    return uuid.uuid4().hex[:8]


@pytest.fixture
def gated_sale():
    """A cash sale of 100 left exactly as the approval gate leaves one."""
    made = {}
    with flask_app.app_context():
        def account(prefix, name, kind):
            a = Account(account_number=f'{prefix}{_uid()[:5]}', name=f'{name} {_uid()}', type=kind)
            db.session.add(a)
            db.session.flush()
            return a

        cash_acc = account('97', 'خزينة', 'Asset')
        cust_acc = account('98', 'عميل', 'Asset')
        rev_acc = account('99', 'مبيعات', 'Revenue')
        box = SafeBox(name=f'خزينة {_uid()}', safe_type='cash', account_id=cash_acc.id, is_active=True)
        db.session.add(box)
        db.session.flush()
        pm = PaymentMethod(name=f'نقد {_uid()}', payment_type='cash', default_safe_box_id=box.id,
                           commission_rate=0.0, commission_timing='invoice', is_active=True)
        customer = Customer(customer_code=f'C-{_uid()}', name=f'عميل {_uid()}', account_id=cust_acc.id)
        db.session.add_all([pm, customer])
        db.session.flush()
        invoice = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع',
                          customer_id=customer.id, date=datetime.now(), total=100.0,
                          amount_paid=100.0, status='paid', is_posted=False, posted_by='بائع')
        db.session.add(invoice)
        db.session.flush()
        je = JournalEntry(entry_number=f'JE-T-{_uid()}', date=invoice.date, description='فاتورة بيع',
                          reference_type='invoice', reference_id=invoice.id,
                          is_posted=False, is_draft=False, created_by='بائع')
        db.session.add(je)
        db.session.flush()
        db.session.add_all([
            JournalEntryLine(journal_entry_id=je.id, account_id=cust_acc.id, cash_debit=100.0, cash_credit=0.0),
            JournalEntryLine(journal_entry_id=je.id, account_id=rev_acc.id, cash_debit=0.0, cash_credit=100.0),
            InvoicePayment(invoice_id=invoice.id, payment_method_id=pm.id, amount=100.0, net_amount=100.0),
            SystemAlert(alert_type='invoice_approval', severity='critical', title='فاتورة تحتاج اعتماد',
                        entity_type='Invoice', entity_id=invoice.id, created_by='بائع'),
        ])
        db.session.commit()
        made.update(invoice=invoice.id, cash=cash_acc.id, customer=cust_acc.id, revenue=rev_acc.id,
                    box=box.id, pm=pm.id, customer_id=customer.id)
    yield made
    with flask_app.app_context():
        entry_ids = [j.id for j in JournalEntry.query.filter(
            JournalEntry.reference_id == made['invoice'],
            JournalEntry.reference_type.in_(['invoice', 'invoice_payments'])).all()]
        if entry_ids:
            JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entry_ids)).delete(synchronize_session=False)
            purge(lambda: JournalEntry.query.filter(JournalEntry.id.in_(entry_ids)).delete(synchronize_session=False))
        SafeBoxTransaction.query.filter_by(invoice_id=made['invoice']).delete(synchronize_session=False)
        SystemAlert.query.filter_by(entity_type='Invoice', entity_id=made['invoice']).delete(synchronize_session=False)
        InvoicePayment.query.filter_by(invoice_id=made['invoice']).delete(synchronize_session=False)
        purge(lambda: Invoice.query.filter_by(id=made['invoice']).delete(synchronize_session=False))
        Customer.query.filter_by(id=made['customer_id']).delete(synchronize_session=False)
        PaymentMethod.query.filter_by(id=made['pm']).delete(synchronize_session=False)
        SafeBox.query.filter_by(id=made['box']).delete(synchronize_session=False)
        Account.query.filter(Account.id.in_([made['cash'], made['customer'], made['revenue']])).delete(synchronize_session=False)
        db.session.commit()


def _posted_balance(account_id):
    rows = (db.session.query(JournalEntryLine.cash_debit, JournalEntryLine.cash_credit)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntryLine.account_id == account_id, JournalEntry.is_posted.is_(True),
                    JournalEntryLine.is_deleted.is_(False)).all())
    return round(sum((d or 0) - (c or 0) for d, c in rows), 2)


@pytest.mark.parametrize('route', list(ROUTES.values()), ids=list(ROUTES))
def test_every_approval_leaves_the_same_complete_posting(route, gated_sale, auth_headers):
    resp = _call(flask_app.test_client(), route, gated_sale['invoice'], auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:400]
    with flask_app.app_context():
        invoice = Invoice.query.get(gated_sale['invoice'])
        assert invoice.is_posted
        entries = JournalEntry.query.filter(JournalEntry.reference_id == invoice.id,
                                            JournalEntry.reference_type.in_(['invoice', 'invoice_payments'])).all()
        assert entries and all(je.is_posted for je in entries), \
            [(je.reference_type, je.is_posted) for je in entries]
        assert any(je.reference_type == 'invoice_payments' for je in entries), 'the cash payment has no entry'
        assert _posted_balance(gated_sale['cash']) == 100.0, 'the cash did not reach the safe box account'
        assert _posted_balance(gated_sale['customer']) == 0.0, 'the customer does not net to zero'
        assert _posted_balance(gated_sale['revenue']) == -100.0, 'the sale is not in the books'
        assert SafeBoxTransaction.query.filter_by(invoice_id=invoice.id, safe_box_id=gated_sale['box']).count() == 1
        alert = SystemAlert.query.filter_by(entity_type='Invoice', entity_id=invoice.id).one()
        assert alert.is_reviewed, 'the approval alert stays in the bell after approval'


@pytest.mark.parametrize('route', list(ROUTES.values()), ids=list(ROUTES))
def test_an_approved_invoice_is_not_approved_twice(route, gated_sale, auth_headers):
    client = flask_app.test_client()
    assert _call(client, route, gated_sale['invoice'], auth_headers).status_code == 200
    again = _call(client, route, gated_sale['invoice'], auth_headers)
    if route.endswith('post-batch'):
        assert again.status_code == 200 and again.get_json()['skipped_count'] == 1
    else:
        assert again.status_code == 400
    with flask_app.app_context():
        assert _posted_balance(gated_sale['cash']) == 100.0


def test_one_posting_serves_every_route():
    """The four routes call post_invoice_document and restate none of it."""
    import inspect
    import posting_routes
    from routes import invoices as invoice_routes
    for fn in (posting_routes.post_invoice, posting_routes.approve_large_discount_invoice,
               posting_routes.post_invoices_batch, invoice_routes.approve_invoice):
        src = inspect.getsource(fn)
        assert 'post_invoice_document(' in src, fn.__name__
        for restated in ('_create_deferred_payment_entries(', '_append_safe_transactions_for_invoice_gold(',
                         'is_posted = True'):
            assert restated not in src, f'{fn.__name__} restates {restated}'
