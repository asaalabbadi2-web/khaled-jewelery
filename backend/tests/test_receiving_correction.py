"""A received document's weights corrected by «تصحيح فاتورة» (ADR-087 R1.5 step B).

The owner, 8 Nov 2026: a receipt is never unposted; it is corrected by a
documented entry, the original standing. The one correction document (ت-1:
the line in place, the difference one entry on its day, the record of what
was and is) now takes a supplier's purchase received: a weight received
wrong, a supplier's paper read wrong -- the stock moves by what was received,
the supplier's gold by his paper, the rest on the count's roles within the
tolerance, above it the owner's or the manager's approval. Invoiced, its cash
too (step C); a purchase posted whole before receiving is not corrected here.

Run:
    python -m pytest tests/test_receiving_correction.py -v
"""
import pytest

from models import Account, InvoiceCorrection, InvoiceItem, JournalEntry, JournalEntryLine, db
from services.invoice_corrections import CorrectionRefused, correct_line
from tests.test_receiving_completes_one_document import _call, _id
from tests.test_receiving_weight_difference import _receipt
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


@pytest.fixture
def showroom(world):
    world['display'].stock_location = 'showroom'
    db.session.flush()
    return world['display']


def _received(auth_headers, world, received=20.0, paper=None):
    status, body = _call(auth_headers, _receipt(world, received, paper), posting_part='gold')
    assert status == 201, body
    invoice = db.session.get(__import__('models').Invoice, _id(body))
    return invoice, InvoiceItem.query.filter_by(invoice_id=invoice.id).one()


def _correct(invoice, item, safe, **line):
    return correct_line(invoice, line_id=item.id, safe_box_id=safe.id, reason='ميزان', by='t', now=NOW,
                        lines=[{'karat': 21, 'category_id': item.category_id, **line}])


def _grams(entry_id, account_id):
    lines = JournalEntryLine.query.filter_by(journal_entry_id=entry_id, account_id=account_id).all()
    return round(sum(float(l.debit_21k or 0) - float(l.credit_21k or 0) for l in lines), 3)


def _twin(world):
    return db.session.get(Account, world['supplier'].account_id).memo_account_id


def test_a_weight_received_wrong_moves_the_stock_and_the_supplier_by_it(auth_headers, world, roles, showroom):
    invoice, item = _received(auth_headers, world, 20.0)
    correction = _correct(invoice, item, showroom, weight=19.5)
    entry = correction.journal_entry_id
    assert _grams(entry, showroom.account_id) == -0.5
    assert _grams(entry, _twin(world)) == 0.5, 'his paper said what was received: he is owed less'
    assert db.session.get(JournalEntry, entry).entry_number.startswith('COR')
    item = db.session.get(InvoiceItem, item.id)
    assert (item.weight, item.supplier_weight) == (19.5, 19.5), 'the line in place'
    assert InvoiceCorrection.query.filter_by(invoice_id=invoice.id).count() == 1


def test_the_suppliers_paper_read_wrong_moves_his_gold_the_rest_on_the_counts(auth_headers, world, roles,
                                                                            showroom):
    invoice, item = _received(auth_headers, world, 20.0)
    correction = _correct(invoice, item, showroom, weight=20.0, supplier_weight=20.05)
    entry = correction.journal_entry_id
    assert _grams(entry, showroom.account_id) == 0.0
    assert _grams(entry, _twin(world)) == -0.05
    assert _grams(entry, roles['shortage_w'].id) == 0.05
    assert db.session.get(InvoiceItem, item.id).supplier_weight == 20.05


def test_above_the_tolerance_the_owners_or_the_managers(auth_headers, world, roles, showroom):
    invoice, item = _received(auth_headers, world, 20.0)
    with pytest.raises(CorrectionRefused) as refused:
        _correct(invoice, item, showroom, weight=19.6, supplier_weight=20.0)
    assert refused.value.code == 'receipt_difference_over_tolerance'


def test_invoiced_its_cash_is_step_c_and_a_whole_purchase_is_not_corrected_here(auth_headers, world, roles,
                                                                               showroom):
    build, _ = SHAPES['items only, no VAT']
    invoice, item = _received(auth_headers, world, 20.0)
    _call(auth_headers, build(world), posting_part='cash', complete_invoice_id=invoice.id)
    with pytest.raises(CorrectionRefused) as refused:
        _correct(invoice, item, showroom, weight=19.5)
    # invoiced is step C (tests/test_receiving_correction_invoiced.py); this
    # shape's wage is on the invoice alone, none on its line
    assert refused.value.code == 'correction_wage_lines_unknown'
    status, body = _call(auth_headers, build(world))
    whole = db.session.get(__import__('models').Invoice, _id(body))
    with pytest.raises(CorrectionRefused) as refused:
        _correct(whole, InvoiceItem.query.filter_by(invoice_id=whole.id).one(), showroom, weight=19.5)
    assert refused.value.code == 'correction_not_built_for_type'
