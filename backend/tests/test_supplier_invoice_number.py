"""The supplier's own invoice number on a purchase (the owner, 8 Nov 2026).

Optional; once written, one per supplier among the invoices not retracted --
a rejected invoice entered again keeps its number; another supplier may have
the same. Trimmed, its Arabic digits read as Latin. Refused naming the
invoice that has it.

Run:
    python -m pytest tests/test_supplier_invoice_number.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import Invoice, Supplier, db
from services.purchase_lines import PurchaseLineRefused, supplier_invoice_number


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _supplier():
    s = Supplier(supplier_code=f'S-N-{uuid.uuid4().hex[:6]}', name=f'مورد {uuid.uuid4().hex[:6]}')
    db.session.add(s)
    db.session.flush()
    return s


def _purchase(supplier, number, status='unpaid'):
    inv = Invoice(invoice_type='شراء', invoice_type_id=uuid.uuid4().int % 10**8, supplier_id=supplier.id,
                  date=datetime(2026, 11, 8), total=0.0, supplier_invoice_number=number, status=status)
    db.session.add(inv)
    db.session.flush()
    return inv


def test_empty_is_none_and_written_is_read_as_latin():
    s = _supplier()
    assert supplier_invoice_number('شراء', s.id, '  ') is None
    assert supplier_invoice_number('شراء', s.id, None) is None
    assert supplier_invoice_number('شراء', s.id, ' ١٢٣٤ ') == '1234'


def test_one_per_supplier_naming_the_invoice_that_has_it():
    s = _supplier()
    _purchase(s, '1234')
    with pytest.raises(PurchaseLineRefused) as refused:
        supplier_invoice_number('شراء', s.id, '١٢٣٤')
    assert refused.value.code == 'supplier_invoice_number_taken'
    assert '1234' in refused.value.message


def test_another_supplier_may_have_it_and_a_rejected_invoice_gives_it_back():
    s, other = _supplier(), _supplier()
    _purchase(s, '77', status='rejected')
    assert supplier_invoice_number('شراء', s.id, '77') == '77'
    _purchase(s, '78')
    assert supplier_invoice_number('شراء', other.id, '78') == '78'


def test_only_a_supplier_purchase_has_it():
    with pytest.raises(PurchaseLineRefused):
        supplier_invoice_number('بيع', None, '5')


def test_the_database_holds_it_too():
    from sqlalchemy.exc import IntegrityError
    s = _supplier()
    _purchase(s, '900')
    with pytest.raises(IntegrityError):
        with db.session.begin_nested():
            _purchase(s, '900')


def test_the_route_refuses_a_number_taken(auth_headers):
    from app import app as flask_app
    from tests.purchase_category import categorized
    s = _supplier()
    _purchase(s, 'A-1')
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'invoice_type': 'شراء', 'gold_type': 'new', 'supplier_id': s.id, 'supplier_invoice_number': 'A-1',
        'items': categorized([{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1}])})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'supplier_invoice_number_taken'
