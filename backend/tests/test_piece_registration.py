"""A piece is born on receiving, by one writer (ADR-087 R3.1, §5).

A category says how it is tracked: by weight (every one today) or by the
piece (the owner's first wave: bangles of 21k...). A posted receipt's line
in a piece category registers its pieces, one by one: each its own number
«KJ-» and six digits or more, never reused; its weight, its stones; its
line's category and karat. The pieces of a line weigh no more than it -- the
rest stays weight in its category. In the books nothing moves: the line's
grams were allocated to its category on receiving; a piece takes its share
of that allocation under its own number.

Run:
    python -m pytest tests/test_piece_registration.py -v
"""
import pytest

from models import Category, Item, StockLineAllocation, db
from services.pieces import PieceRefused, register_piece
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


@pytest.fixture
def bangles_by_the_piece(world):
    def _of(item):
        category = db.session.get(Category, item.category_id)
        category.tracking = 'piece'
        db.session.flush()
        return category
    return _of


def _allocated(item):
    rows = (StockLineAllocation.query.filter_by(category_id=item.category_id)
            .filter(StockLineAllocation.journal_entry_line_id.in_(_lines(item))).all())
    return {(a.item_id is not None): round(sum(r.grams for r in rows if (r.item_id is not None) == (a.item_id is not None)), 3)
            for a in rows}


def _lines(item):
    from models import JournalEntry, JournalEntryLine
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=item.invoice_id)]
    return [l.id for l in JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries))]


def test_a_category_is_tracked_by_weight_unless_said():
    assert Category(name='x', karat='21').tracking in (None, 'weight')


def test_a_piece_is_registered_under_its_line_with_its_own_number(auth_headers, world, roles, showroom,
                                                                  bangles_by_the_piece):
    _, line = _received(auth_headers, world, 20.0)
    bangles_by_the_piece(line)
    first = register_piece(line, weight=12.45, by='t', now=NOW)
    second = register_piece(line, weight=7.0, by='t', now=NOW)
    assert first.item_code.startswith('KJ-') and len(first.item_code) >= 9
    assert first.item_code != second.item_code
    assert (first.receipt_item_id, first.category_id, float(first.karat), first.weight) == (line.id, line.category_id, 21.0, 12.45)
    assert _allocated(line) == {True: 19.45, False: 0.55}, 'the line\'s grams: 19.45 under its pieces, 0.55 the rest'


def test_no_heavier_than_the_line_left(auth_headers, world, roles, showroom, bangles_by_the_piece):
    _, line = _received(auth_headers, world, 20.0)
    bangles_by_the_piece(line)
    register_piece(line, weight=15.0, by='t', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        register_piece(line, weight=5.01, by='t', now=NOW)
    assert refused.value.code == 'piece_heavier_than_rest'


def test_a_weight_category_registers_no_piece(auth_headers, world, roles, showroom):
    _, line = _received(auth_headers, world, 20.0)
    with pytest.raises(PieceRefused) as refused:
        register_piece(line, weight=5.0, by='t', now=NOW)
    assert refused.value.code == 'piece_category_by_weight'


def test_only_a_line_received_and_standing(auth_headers, world, roles, showroom, bangles_by_the_piece):
    from services.invoice_corrections import cancel_receipt
    invoice, line = _received(auth_headers, world, 20.0)
    bangles_by_the_piece(line)
    cancel_receipt(invoice, safe_box_id=showroom.id, reason='مورد خاطئ', by='t', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        register_piece(line, weight=5.0, by='t', now=NOW)
    assert refused.value.code == 'piece_line_not_received'


def test_a_line_with_pieces_is_not_corrected_below_them_nor_cancelled(auth_headers, world, roles, showroom,
                                                                      bangles_by_the_piece):
    """ADR-087 §5, the owner's fifth control: a receipt with pieces is not
    cancelled while they stand; its line not corrected below them."""
    from services.invoice_corrections import CorrectionRefused, cancel_receipt, correct_line
    invoice, line = _received(auth_headers, world, 20.0)
    bangles_by_the_piece(line)
    register_piece(line, weight=12.0, by='t', now=NOW)
    with pytest.raises(CorrectionRefused) as refused:
        correct_line(invoice, line_id=line.id, safe_box_id=showroom.id, reason='x', by='t', now=NOW,
                     lines=[{'karat': 21, 'weight': 11.0, 'category_id': line.category_id}])
    assert refused.value.code == 'correction_below_its_pieces'
    with pytest.raises(CorrectionRefused) as refused:
        cancel_receipt(invoice, safe_box_id=showroom.id, reason='x', by='t', now=NOW)
    assert refused.value.code == 'receipt_has_pieces'
    correct_line(invoice, line_id=line.id, safe_box_id=showroom.id, reason='الميزان', by='t', now=NOW,
                 lines=[{'karat': 21, 'weight': 19.5, 'category_id': line.category_id}])
