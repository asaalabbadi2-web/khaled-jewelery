"""A piece is sold once, by its weight, its wage known (ADR-087 R3.2; ADR-045, ADR-085 law 3).

A sale's line naming a piece: the piece is in the stock (its allocations on
posted lines add to more than nothing -- a sale takes them to nothing, so it
is not sold twice); its receipt's invoice is completed -- a coded piece never
leaves with an unknown wage (the owner's law 8, 8 Nov 2026); the line is the
piece's weight. A category tracked by the piece is sold by its pieces only.

Run:
    python -m pytest tests/test_piece_sale.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import JournalEntry, JournalEntryLine, db
from services.pieces import PieceRefused, refuse_piece_sales, register_piece
from services.stock_ledger import allocate
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_completes_one_document import _call
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


def _piece(auth_headers, world, showroom, bangles_by_the_piece, *, invoiced=True):
    invoice, line = _received(auth_headers, world, 20.0)
    bangles_by_the_piece(line)
    piece = register_piece(line, weight=14.37, by='t', now=NOW)
    if invoiced:
        build, _ = SHAPES['items only, no VAT']
        payload = build(world)
        payload['items'][0].update(weight=20.0, category_id=line.category_id)
        status, body = _call(auth_headers, payload, posting_part='cash', complete_invoice_id=invoice.id)
        assert status in (200, 201), body
    return piece


def _line(piece, **kw):
    return {'item_id': piece.id, 'karat': 21, 'weight': piece.weight, 'category_id': piece.category_id, **kw}


def _refusal(items):
    try:
        refuse_piece_sales('بيع', items)
    except PieceRefused as refused:
        return refused.code
    return None


def test_a_piece_in_stock_its_wage_known_is_sold(auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    assert _refusal([_line(piece)]) is None


def test_its_wage_unknown_it_is_not(auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece, invoiced=False)
    assert _refusal([_line(piece)]) == 'piece_wage_unknown'


def test_sold_it_is_not_sold_again(auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    je = JournalEntry(entry_number=f'JE-S-{uuid.uuid4().hex[:8]}', date=datetime(2026, 11, 9), description='بيع',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    sold = JournalEntryLine(journal_entry_id=je.id, account_id=showroom.account_id, description='بيع',
                            credit_21k=piece.weight)
    db.session.add(sold)
    db.session.flush()
    allocate(sold, 21, piece.category_id, -piece.weight, item_id=piece.id, by='t', now=NOW)
    assert _refusal([_line(piece)]) == 'piece_sold'


def test_by_its_weight_and_a_piece_category_by_its_pieces(auth_headers, world, roles, showroom,
                                                          bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    assert _refusal([_line(piece, weight=14.0)]) == 'piece_weight_differs'
    assert _refusal([{'karat': 21, 'weight': 5.0, 'category_id': piece.category_id}]) == 'piece_category_sold_by_piece'


def test_the_sale_route_refuses_it(auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece, invoiced=False)
    status, body = _call(auth_headers, {'invoice_type': 'بيع', 'gold_type': 'new', 'items': [_line(piece)]})
    assert status == 400 and body['error'] == 'piece_wage_unknown', body
