"""A category tracked by the piece never holds less than its pieces (the owner, 18 Nov 2026).

Probed on a copy of the 17 Nov production: a supplier's return of 44 g of a
receipt line all coded into pieces took the grams out of the category under
no piece -- nine pieces held 187 g, the category 143 g -- and nothing said so.
The nightly check says it: a stock safe's grams of such a category under no
piece below zero.

Run:
    python -m pytest tests/test_pieces_beyond_category.py -v
"""
import uuid
from datetime import datetime

from models import JournalEntry, JournalEntryLine, db
from services.books_invariants import PIECES_BEYOND_CATEGORY, check_pieces_beyond_category
from services.stock_ledger import allocate
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_sale import _piece
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _out_without_pieces(showroom, category_id, grams):
    je = JournalEntry(entry_number=f'JE-R-{uuid.uuid4().hex[:8]}', date=datetime(2026, 11, 18), entry_type='عادي',
                      description='مرتجع شراء', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=showroom.account_id, description='مرتجع',
                            credit_21k=grams)
    db.session.add(line)
    db.session.flush()
    allocate(line, 21, category_id, -grams, by='t', now=NOW)


def _found(showroom, category_id):
    return {f.subject_key: f for f in check_pieces_beyond_category()}.get(f'safe_box:{showroom.id}:21k:category:{category_id}')


def test_gold_out_without_its_pieces_is_said(auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)    # 20 g: 14.37 a piece, 5.63 its rest
    _out_without_pieces(showroom, piece.category_id, 5.0)
    assert _found(showroom, piece.category_id) is None, 'the rest held it'
    _out_without_pieces(showroom, piece.category_id, 4.0)
    fact = _found(showroom, piece.category_id)
    assert fact is not None and fact.kind == PIECES_BEYOND_CATEGORY
    assert round(fact.metric, 3) == -3.37
