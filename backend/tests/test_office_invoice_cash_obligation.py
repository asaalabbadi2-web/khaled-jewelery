"""An office reservation invoice owes CASH, not wages — its ceiling is `total`.

Phase 13 gave every `شراء` invoice the same cash ceiling: manufacturing wage
plus taxes, excluding the gold value, because a worked-gold supplier is settled
**gold for gold** and only the wage is a cash debt. That rule was right for the
type it was written for and too wide for the discriminator it used.

A closing office (مكتب تسكير) is the opposite trade: raw gold is reserved from
it and **settled in cash**. So its invoice's entire value IS the cash debt, and
it carries no gold obligation at all — which is exactly why
is_gold_obligation_eligible() already excludes it (Phase 16A proved those
invoices post cash only, never a weight column).

Measured on real data before this changed: all 29 office invoices had
wage_subtotal = 0, so the Phase 13 formula gave them a ceiling of 0 while
`total` matched their recorded payments to the riyal — 175,100 paid against a
175,100 total reading `paid`, 150,000 against 170,349 reading `partially_paid`.
The stored data was coherent; the ceiling was not.

Run:
    python -m pytest tests/test_office_invoice_cash_obligation.py -v
"""

import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Invoice, Supplier, db
from services.gold_allocation_service import is_gold_obligation_eligible


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app):
    connection = db.engine.connect()
    transaction = connection.begin()
    db.session.bind = connection
    nested = connection.begin_nested()
    yield
    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier(*, wage_type='cash'):
    s = Supplier(
        supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}',
        default_wage_type=wage_type,
    )
    db.session.add(s)
    db.session.flush()
    return s


def _invoice(*, office_id=None, supplier_id=None, total=100000.0,
             wage=0.0, wage_tax=0.0, gold_tax=0.0, invoice_type='شراء'):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type=invoice_type,
        supplier_id=supplier_id, office_id=office_id, date=datetime.now(),
        total=total, wage_subtotal=wage, wage_tax_total=wage_tax,
        gold_tax_total=gold_tax, status='unpaid', amount_paid=0.0,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


class TestOfficeInvoiceOwesItsWholeValueInCash:

    def test_ceiling_is_total_not_wage_plus_taxes(self):
        """The red witness for this change: with the Phase 13 formula an office
        invoice with wage_subtotal 0 had a ceiling of 0, so a real 175,100 SAR
        settlement had nothing to settle against."""
        invoice = _invoice(office_id=4, total=175100.0, wage=0.0)
        assert invoice.cash_obligation == 175100.0

    def test_a_partial_office_settlement_reads_partial_against_total(self):
        invoice = _invoice(office_id=4, total=170349.0, wage=0.0)
        assert invoice.cash_obligation == 170349.0

    def test_an_office_invoice_carries_no_gold_obligation(self):
        """The mirror of the same business fact: gold is reserved from the
        office and settled in cash, so there is no gold debt to track."""
        invoice = _invoice(office_id=4, total=175100.0)
        assert is_gold_obligation_eligible(invoice) is False

    def test_office_wins_over_the_purchase_formula_even_with_wages_present(self):
        """The discriminator is the trade, not the absence of a wage figure."""
        invoice = _invoice(office_id=7, total=50000.0, wage=900.0, wage_tax=135.0)
        assert invoice.cash_obligation == 50000.0


class TestWorkedGoldSupplierIsUnchanged:

    def test_wage_in_cash_still_gives_wage_plus_taxes(self):
        supplier = _supplier(wage_type='cash')
        invoice = _invoice(
            supplier_id=supplier.id, total=99999.0,
            wage=1000.0, wage_tax=150.0, gold_tax=250.0,
        )
        assert invoice.cash_obligation == 1400.0

    def test_wage_in_gold_still_excludes_the_wage(self):
        supplier = _supplier(wage_type='gold')
        invoice = _invoice(
            supplier_id=supplier.id, total=99999.0,
            wage=1000.0, wage_tax=150.0, gold_tax=250.0,
        )
        assert invoice.cash_obligation == 400.0

    def test_a_supplier_invoice_still_carries_a_gold_obligation(self):
        supplier = _supplier()
        invoice = _invoice(supplier_id=supplier.id, total=99999.0)
        assert is_gold_obligation_eligible(invoice) is True

    def test_other_invoice_types_still_use_total(self):
        invoice = _invoice(invoice_type='بيع', total=7500.0, wage=100.0)
        assert invoice.cash_obligation == 7500.0
