"""An invoiced receipt corrected: its wage, its VAT, the cash it owes (ADR-087 R1.5 step C).

A purchase received and completed -- the screen's own (12.5 g of 21k at 18 a
gram, the wages' VAT at 15 %) -- corrected by «تصحيح فاتورة»: a wage per gram
typed wrong is its difference on the wages (1320, capitalized) and their VAT
(1400) against the supplier's cash; a weight received wrong is its gold (step
B) and its wage, the gram's wage following the weight. The invoice's totals
follow. A purchase whose lines do not carry its wage (the old whole shapes),
or whose gold carries VAT, is refused by name.

Run:
    python -m pytest tests/test_receiving_correction_invoiced.py -v
"""
import pytest

from models import Account, Invoice, InvoiceItem, JournalEntryLine, db
from services.invoice_corrections import CorrectionRefused, correct_line
from tests.test_receiving_completes_one_document import _call, _id
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_receiving_parts_are_the_whole import _screen
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


def _invoiced(auth_headers, world, build=_screen):
    status, body = _call(auth_headers, build(world), posting_part='gold')
    assert status == 201, body
    receipt = _id(body)
    status, body = _call(auth_headers, build(world), posting_part='cash', complete_invoice_id=receipt)
    assert status in (200, 201), body
    invoice = db.session.get(Invoice, receipt)
    return invoice, InvoiceItem.query.filter_by(invoice_id=invoice.id).one()


def _correct(invoice, item, safe, **line):
    return correct_line(invoice, line_id=item.id, safe_box_id=safe.id, reason='الأجرة', by='t', now=NOW,
                        lines=[{'karat': 21, 'category_id': item.category_id, 'weight': item.weight, **line}])


def _cash(entry_id, number):
    account = Account.query.filter_by(account_number=number).first()
    lines = JournalEntryLine.query.filter_by(journal_entry_id=entry_id, account_id=account.id).all()
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in lines), 2)


def _supplier_cash(entry_id, world):
    lines = JournalEntryLine.query.filter_by(journal_entry_id=entry_id, account_id=world['supplier'].account_id).all()
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in lines), 2)


def test_a_wage_typed_wrong_is_its_difference_with_its_vat(auth_headers, world, roles, showroom):
    invoice, item = _invoiced(auth_headers, world)
    total = float(invoice.total)
    correction = _correct(invoice, item, showroom, wage_per_gram=20.0)
    entry = correction.journal_entry_id
    assert _cash(entry, '1320') == 25.0, '12.5 g x 2'
    assert _cash(entry, '1400') == 3.75, 'its VAT at 15 %'
    assert _supplier_cash(entry, world) == -28.75, 'owed in cash'
    assert db.session.get(InvoiceItem, item.id).wage == 20.0
    assert float(invoice.total) == pytest.approx(total + 28.75)
    assert float(invoice.wage_subtotal) == pytest.approx(250.0)


def test_a_weight_received_wrong_takes_its_wage_with_it(auth_headers, world, roles, showroom):
    invoice, item = _invoiced(auth_headers, world)
    correction = _correct(invoice, item, showroom, weight=12.0)
    entry = correction.journal_entry_id
    assert _cash(entry, '1320') == -9.0, '0.5 g x 18'
    assert _cash(entry, '1400') == -1.35
    assert _supplier_cash(entry, world) == 10.35
    lines = JournalEntryLine.query.filter_by(journal_entry_id=entry, account_id=showroom.account_id).all()
    assert round(sum(float(l.debit_21k or 0) - float(l.credit_21k or 0) for l in lines), 3) == -0.5


def test_lines_that_do_not_carry_its_wage_are_refused(auth_headers, world, roles, showroom):
    build, _ = SHAPES['items only, no VAT']     # its wage on the invoice, none on its line
    invoice, item = _invoiced(auth_headers, world, build)
    with pytest.raises(CorrectionRefused) as refused:
        _correct(invoice, item, showroom, wage_per_gram=60.0)
    assert refused.value.code == 'correction_wage_lines_unknown'
