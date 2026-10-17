"""An invoice's type is shown by the owner's names, stored as before (17 Oct 2026).

«شراء من عميل» reads «شراء كسر», a supplier's «شراء» reads «شراء جديد», an
office's settled reservation -- stored «شراء» too, but scrap -- reads «شراء كسر
من مكتب», and the returns follow. The stored invoice_type does not change.

Run:
    python -m pytest tests/test_invoice_type_labels.py -v
"""
import pytest

from services.invoice_type_labels import invoice_type_label


@pytest.mark.parametrize('stored, office_id, shown', [
    ('شراء من عميل', None, 'شراء كسر'),
    ('شراء', None, 'شراء جديد'),
    ('شراء من مورد', None, 'شراء جديد'),
    ('شراء', 7, 'شراء كسر من مكتب'),
    ('مرتجع شراء', None, 'مرتجع شراء كسر'),
    ('مرتجع شراء (مورد)', None, 'مرتجع شراء جديد'),
    ('بيع', None, 'بيع'),
    ('مرتجع بيع', None, 'مرتجع بيع'),
    (None, None, ''),
])
def test_the_owner_s_names(stored, office_id, shown):
    assert invoice_type_label(stored, office_id=office_id) == shown


def test_an_invoice_answers_its_name_beside_its_stored_type():
    from app import app as flask_app
    from models import Invoice
    with flask_app.app_context():
        import datetime
        inv = Invoice(invoice_type='شراء من عميل', invoice_type_id=987654321, total=0.0, gold_type='scrap',
                      date=datetime.datetime(2026, 10, 17))
        data = inv.to_dict()
        assert (data['invoice_type'], data['invoice_type_label']) == ('شراء من عميل', 'شراء كسر')
