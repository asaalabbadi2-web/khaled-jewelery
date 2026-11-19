"""A piece coded from the stock on hand carries the wage written for it (ADR-096 §4, ت4).

The owner, 19 Nov 2026: no supplier invoices exist for the stock older than
the system, «ولكن اجورها معروفه، اثناء الجرد سنكتب اجور كل قطعه».

- A batch of the stock on hand takes no wage: each of its pieces is
  registered with its own wage, per gram or the piece's whole.
- No wage, no piece; zero is a wage.
- The piece's wage is what was written, kept on it; a sale releases it, per
  gram unrounded, and refuses any other.
- A receipt's piece takes its invoice's wage: one written for it is refused.

Run:
    python -m pytest tests/test_piece_wage_written_at_coding.py -v
"""
import pytest

from models import Category, db
from services.pieces import (PieceRefused, line_wages, open_coding, piece_wage, refuse_piece_sales,
                             register_piece, wages_per_gram)
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_coding import _stock, bangles, receiving  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


def _batch(safe, category, weight):
    return open_coding(safe_box_id=safe.id, category_id=category.id, weight=weight, by='t', now=NOW)


def _refusal(source, **kw):
    try:
        register_piece(source, **{'by': 't', 'now': NOW, **kw})
    except PieceRefused as refused:
        return refused.code
    return None


def test_each_piece_carries_the_wage_written_for_it(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 50.0)
    batch = _batch(showroom, bangles, 40.0)
    by_gram = register_piece(batch, weight=12.40, wage=20, by='t', now=NOW)
    whole = register_piece(batch, weight=10.0, wage=300, wage_whole=True, by='t', now=NOW)
    third = register_piece(batch, weight=10.01, wage=12.333, by='t', now=NOW)
    assert (piece_wage(by_gram), piece_wage(whole), piece_wage(third)) == (248.0, 300.0, round(12.333 * 10.01, 2))
    wages = line_wages(batch)
    assert wages['pieces'] == {by_gram.id: 248.0, whole.id: 300.0, third.id: round(12.333 * 10.01, 2)}
    assert wages['line'] == round(248.0 + 300.0 + round(12.333 * 10.01, 2), 2)
    per_gram = wages_per_gram([by_gram, whole, third])
    assert (per_gram[by_gram.id], per_gram[whole.id]) == (20.0, 30.0), 'each its own, not the batch'


def test_a_sale_releases_the_pieces_own_wage(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 20.0)
    batch = _batch(showroom, bangles, 20.0)
    piece = register_piece(batch, weight=9.0, wage=100, wage_whole=True, by='t', now=NOW)
    per_gram = round(100 / 9.0, 6)
    refuse_piece_sales('بيع', [{'item_id': piece.id, 'weight': 9.0, 'karat': 21, 'wage': per_gram}])
    with pytest.raises(PieceRefused) as refused:
        refuse_piece_sales('بيع', [{'item_id': piece.id, 'weight': 9.0, 'karat': 21, 'wage': 11.11}])
    assert refused.value.code == 'piece_wage_differs'


def test_no_wage_no_piece_and_zero_is_a_wage(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 20.0)
    batch = _batch(showroom, bangles, 20.0)
    assert _refusal(batch, weight=5.0) == 'piece_wage_required'
    assert _refusal(batch, weight=5.0, wage='') == 'piece_wage_required'
    assert _refusal(batch, weight=5.0, wage='خمسة') == 'piece_wage_invalid'
    assert _refusal(batch, weight=5.0, wage=-1) == 'piece_wage_invalid'
    piece = register_piece(batch, weight=5.0, wage=0, by='t', now=NOW)
    assert piece_wage(piece) == 0.0


def test_a_receipts_piece_takes_its_invoices_wage(app, auth_headers, world, roles, showroom, receiving):
    _, line = _received(auth_headers, world, 30.0)
    category = db.session.get(Category, line.category_id)
    category.tracking = 'piece'
    db.session.flush()
    assert _refusal(line, weight=5.0, wage=20) == 'piece_wage_from_invoice'
    register_piece(line, weight=5.0, by='t', now=NOW)


def test_the_station_writes_each_pieces_wage(app, auth_headers, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 30.0)
    c = app.test_client()
    r = c.post('/api/stock-codings', headers=auth_headers,
               json={'safe_box_id': showroom.id, 'category_id': bangles.id, 'weight': 25, 'wage_per_gram': 14})
    assert r.status_code == 400 and r.get_json()['error'] == 'coding_wage_by_piece', 'a batch takes no wage'
    r = c.post('/api/stock-codings', headers=auth_headers,
               json={'safe_box_id': showroom.id, 'category_id': bangles.id, 'weight': 25})
    assert r.status_code == 201, r.get_data(as_text=True)
    batch = r.get_json()['line']
    assert (batch['wage_by_piece'], batch['wage_per_gram']) == (True, None)
    r = c.post('/api/pieces', headers=auth_headers, json={'coding_id': batch['coding_id'], 'weight': 12.4})
    assert r.status_code == 400 and r.get_json()['error'] == 'piece_wage_required'
    r = c.post('/api/pieces', headers=auth_headers,
               json={'coding_id': batch['coding_id'], 'weight': 12.4, 'wage': 310, 'wage_whole': True})
    assert r.status_code == 201, r.get_data(as_text=True)
    assert (r.get_json()['piece']['wage'], r.get_json()['piece']['wage_known']) == (310.0, True)
