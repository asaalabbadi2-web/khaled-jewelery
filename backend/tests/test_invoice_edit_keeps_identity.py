"""Editing an unposted invoice corrects it; it stays the same invoice (EDIT-001).

PUT /api/invoices/<id> deletes the invoice and re-creates it through
add_invoice. It passed the original number "to preserve the display number"
(since 2d897d5, 2 Mar 2026) but add_invoice always allocated the next one: on
the 29 Sep copy sale #1540 came back as #1543. And the app sends the moment of
the edit as the date, so the sale moved in time too. The owner's rule
(30 Sep 2026): the number AND the date stay -- an edit corrects the document,
it does not make a new one. And a failed edit said «فشل إعادة إنشاء الفاتورة
بعد الحذف. يرجى إنشاء فاتورة جديدة.» while the whole transaction rolled back
and the original stood untouched: obeying it sold the same thing twice.

The case is invoice 3170's: a scrap purchase from a customer held for
approval above the live price, edited from the app.

Run:
    python -m pytest tests/test_invoice_edit_keeps_identity.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Customer, Employee, Invoice, PaymentMethod, SafeBox, db

ORIGINAL_DATE = '2026-09-29T19:35:00'


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _cash_method():
    box = SafeBox(name='خزينة تعديل', safe_type='cash', account_id=Account.query.get(15).id, is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(payment_type='cash', name='نقداً - تعديل', commission_rate=0.0,
                       commission_timing='invoice', is_active=True, default_safe_box_id=box.id)
    db.session.add(pm)
    db.session.flush()
    return pm


def _payload(pm, *, price, date):
    customer, employee = Customer.query.first(), Employee.query.first()
    return {
        'customer_id': customer.id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': employee.id, 'scrap_holder_employee_id': employee.id,
        'safe_box_id': pm.default_safe_box_id, 'date': date,
        'total': price, 'total_weight': 0.5, 'total_cost': price, 'total_tax': 0.0, 'amount_paid': price,
        'payments': [{'payment_method_id': pm.id, 'amount': price}],
        'items': [{'name': 'حلق اسباني', 'karat': 18, 'weight': 0.5, 'standing_weight': 0.5,
                   'stones_weight': 0.0, 'price': price, 'net': price, 'quantity': 1}],
    }


def _held_purchase(auth_headers):
    pm = _cash_method()
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers,
                                        json=_payload(pm, price=100000.0, date=ORIGINAL_DATE))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    data = resp.get_json()
    assert data['is_posted'] is False, 'the test needs an invoice held for approval'
    return pm, data['id'], data['invoice_type_id']


def test_an_edit_keeps_the_number_and_the_date(auth_headers):
    pm, old_id, number = _held_purchase(auth_headers)
    # What the app sends: the corrected lines, and "now" as the date.
    edit = _payload(pm, price=90000.0, date=datetime.now().isoformat())
    resp = flask_app.test_client().put(f'/api/invoices/{old_id}', headers=auth_headers, json=edit)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    data = resp.get_json()
    edited = Invoice.query.get(data['id'])
    assert edited.invoice_type_id == number, f'number {number} became {edited.invoice_type_id}'
    assert edited.date == datetime.fromisoformat(ORIGINAL_DATE), f'the date moved to {edited.date}'
    assert float(edited.total) == 90000.0
    assert Invoice.query.filter_by(invoice_type='شراء من عميل', invoice_type_id=number).count() == 1


def test_a_failed_edit_says_the_original_is_untouched(auth_headers):
    pm, old_id, number = _held_purchase(auth_headers)
    broken = _payload(pm, price=90000.0, date=datetime.now().isoformat())
    broken['payments'][0]['payment_method_id'] = 999999
    resp = flask_app.test_client().put(f'/api/invoices/{old_id}', headers=auth_headers, json=broken)
    assert resp.status_code >= 400
    body = resp.get_json()
    assert body['error'] == 'edit_failed'
    assert 'لم تتغيّر' in body['message'] and 'بعد الحذف' not in body['message']
    original = Invoice.query.get(old_id)
    assert original is not None and original.invoice_type_id == number and float(original.total) == 100000.0


def test_an_edit_keeps_who_holds_the_purchased_gold(auth_headers):
    """The screen sends the SIGNED-IN user's employee as scrap_holder_employee_id.
    Edited by the owner, invoice 3170's 0.5 g would have moved from the custody of
    the employee who took it in (19) to the owner's -- the custody account is
    who answers for that gold."""
    import uuid
    pm, old_id, _ = _held_purchase(auth_headers)
    holder = Invoice.query.get(old_id).scrap_holder_employee_id
    editor = Employee(employee_code=f'E-{uuid.uuid4().hex[:6]}', name='محرّر', is_active=True)
    db.session.add(editor)
    db.session.flush()
    edit = _payload(pm, price=90000.0, date=datetime.now().isoformat())
    edit['employee_id'] = edit['scrap_holder_employee_id'] = editor.id
    resp = flask_app.test_client().put(f'/api/invoices/{old_id}', headers=auth_headers, json=edit)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert Invoice.query.get(resp.get_json()['id']).scrap_holder_employee_id == holder


def test_an_edit_keeps_the_safe_box_the_gold_went_to(auth_headers):
    """Edited by the owner -- an account with no employee -- the screen sent the
    main scrap safe (31) and invoice 3170's header moved there from the custody of
    the employee who took the gold in (46), while the gold itself stayed in 46.
    The header follows the holder, as the gold does."""
    pm, old_id, _ = _held_purchase(auth_headers)
    original_box = Invoice.query.get(old_id).safe_box_id
    other = SafeBox(name='خزينة ذهب الكسر الرئيسية - تعديل', safe_type='gold',
                    account_id=Account.query.get(15).id, is_active=True)
    db.session.add(other)
    db.session.flush()
    edit = _payload(pm, price=90000.0, date=datetime.now().isoformat())
    edit['safe_box_id'] = other.id
    resp = flask_app.test_client().put(f'/api/invoices/{old_id}', headers=auth_headers, json=edit)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert Invoice.query.get(resp.get_json()['id']).safe_box_id == original_box


def test_the_invoice_says_whether_its_holder_has_a_custody_safe():
    """The app warns an account with no employee that the gold will go to the
    main scrap safe. On an edit the gold stays with the invoice's holder, so the
    app needs to know whether that holder has a custody safe of their own."""
    box = SafeBox(name='عهدة موظف - تعديل', safe_type='gold', account_id=Account.query.get(15).id, is_active=True)
    db.session.add(box)
    db.session.flush()
    holder = Employee.query.first()
    holder.gold_safe_box_id = box.id
    invoice = Invoice(invoice_type='شراء من عميل', invoice_type_id=99001, date=datetime(2026, 9, 29),
                      total=1.0, is_posted=False, scrap_holder_employee_id=holder.id)
    db.session.add(invoice)
    db.session.flush()
    assert invoice.to_dict()['scrap_holder_gold_safe_box_id'] == box.id
    invoice.scrap_holder_employee_id = None
    db.session.flush()
    db.session.expire(invoice, ['scrap_holder_employee'])
    assert invoice.to_dict()['scrap_holder_gold_safe_box_id'] is None
