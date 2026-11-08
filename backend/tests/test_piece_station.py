"""«محطة ترميز القطع»: the server (ADR-087 R3.4; §5, §6).

- A category says how it is tracked -- by weight, or by the piece -- and its
  wage's basis; back to weight refused while a piece of it is held, a scrap
  category never by the piece.
- The station's list: posted receipt lines of categories tracked by the piece
  with weight left to code -- their pieces counted, the rest in grams.
- A piece registered once under its save attempt's key: pressed twice, one.
- Its wage is read, never kept (§6): per gram, its line's wage per gram times
  its weight; awaiting the invoice, none -- and a piece without its wage is
  not sold (law 8). Law 5: the pieces' wages and the rest's are the line's, to
  the halala; with no rest the last piece takes the rounding.

Run:
    python -m pytest tests/test_piece_station.py -v
"""
import pytest

from models import Category, Item, db
from services.pieces import (PieceRefused, line_wages, piece_wage, refuse_piece_sales, register_piece)
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_completes_one_document import _call
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


def _client(app):
    return app.test_client()


def _complete(auth_headers, world, invoice, line, wage_per_gram):
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload['items'][0].update(weight=float(line.weight), category_id=line.category_id, wage=wage_per_gram,
                               manufacturing_wage_per_gram=wage_per_gram)
    status, body = _call(auth_headers, payload, posting_part='cash', complete_invoice_id=invoice.id)
    assert status in (200, 201), body
    db.session.refresh(line)


@pytest.fixture
def coded(world, auth_headers, showroom, bangles_by_the_piece):
    invoice, line = _received(auth_headers, world, 30.0)
    bangles_by_the_piece(line)
    return invoice, line


# ── the category's tracking ─────────────────────────────────────────────────

def test_a_category_is_tracked_by_the_piece_and_back_while_none_is_held(app, auth_headers, world, roles, coded):
    _, line = coded
    category = db.session.get(Category, line.category_id)
    url = f'/api/categories/{category.id}'
    r = _client(app).put(url, headers=auth_headers, json={'tracking': 'weight'})
    assert r.status_code == 200 and r.get_json()['tracking'] == 'weight', r.get_data(as_text=True)
    r = _client(app).put(url, headers=auth_headers, json={'tracking': 'piece'})
    assert r.status_code == 200 and r.get_json()['tracking'] == 'piece', r.get_data(as_text=True)
    register_piece(line, weight=10.0, by='t', now=NOW)
    r = _client(app).put(url, headers=auth_headers, json={'tracking': 'weight'})
    assert r.status_code == 400 and r.get_json()['error'] == 'category_has_pieces', r.get_data(as_text=True)
    r = _client(app).put(url, headers=auth_headers, json={'tracking': 'box'})
    assert r.status_code == 400 and r.get_json()['error'] == 'category_tracking_invalid'


def test_a_scrap_category_is_never_tracked_by_the_piece(app, auth_headers):
    scrap = Category(name='كسر تتبّع (اختبار) 21', karat='21', is_scrap=True)
    db.session.add(scrap)
    db.session.flush()
    r = _client(app).put(f'/api/categories/{scrap.id}', headers=auth_headers, json={'tracking': 'piece'})
    assert r.status_code == 400 and r.get_json()['error'] == 'category_tracking_invalid'


# ── the station's list and its counter ──────────────────────────────────────

def _pending(app, auth_headers):
    r = _client(app).get('/api/pieces/pending', headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    return {row['line_id']: row for row in r.get_json()['lines']}


def test_the_list_holds_the_lines_left_to_code(app, auth_headers, world, roles, coded):
    invoice, line = coded
    row = _pending(app, auth_headers)[line.id]
    assert (row['invoice_number'], row['weight'], row['pieces'], row['rest']) == \
           (invoice.invoice_number, 30.0, 0, 30.0)
    assert row['category_name'] and row['karat'] == 21 and row['stage'] == 'received'
    register_piece(line, weight=14.37, by='t', now=NOW)
    row = _pending(app, auth_headers)[line.id]
    assert (row['pieces'], row['pieces_weight'], row['rest']) == (1, 14.37, 15.63)
    register_piece(line, weight=15.63, by='t', now=NOW)
    assert line.id not in _pending(app, auth_headers), 'a line coded whole leaves the list'


def test_a_weight_category_line_is_not_on_the_list(app, auth_headers, world, roles, showroom):
    _, line = _received(auth_headers, world, 12.0)
    assert line.id not in _pending(app, auth_headers)


# ── registering ─────────────────────────────────────────────────────────────

def test_a_piece_registered_once_under_its_key(app, auth_headers, world, roles, coded):
    _, line = coded
    body = {'line_id': line.id, 'weight': 14.37, 'stones_weight': 0, 'request_key': 'st-1-abc'}
    r1 = _client(app).post('/api/pieces', headers=auth_headers, json=body)
    assert r1.status_code == 201, r1.get_data(as_text=True)
    r2 = _client(app).post('/api/pieces', headers=auth_headers, json=body)
    assert r2.status_code == 200 and r2.get_json().get('already_saved') is True, r2.get_data(as_text=True)
    first, again = r1.get_json(), r2.get_json()
    assert first['piece']['item_code'].startswith('KJ-') and again['piece']['id'] == first['piece']['id']
    assert Item.query.filter_by(receipt_item_id=line.id).count() == 1
    assert first['line']['rest'] == 15.63 and first['line']['pieces'] == 1


def test_a_piece_heavier_than_the_rest_is_refused_saying_why(app, auth_headers, world, roles, coded):
    _, line = coded
    r = _client(app).post('/api/pieces', headers=auth_headers,
                          json={'line_id': line.id, 'weight': 30.5, 'request_key': 'st-2'})
    assert r.status_code == 400 and r.get_json()['error'] == 'piece_heavier_than_rest', r.get_data(as_text=True)
    assert 'أثقل' in r.get_json()['message']


def test_the_line_and_its_pieces(app, auth_headers, world, roles, coded):
    _, line = coded
    register_piece(line, weight=14.37, by='t', now=NOW)
    r = _client(app).get(f'/api/pieces/lines/{line.id}', headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    body = r.get_json()
    assert body['line']['rest'] == 15.63 and [p['weight'] for p in body['pieces']] == [14.37]
    assert body['pieces'][0]['wage'] is None and body['pieces'][0]['wage_known'] is False


# ── the wage: read, never kept ──────────────────────────────────────────────

def test_the_wage_awaits_the_invoice_and_is_then_its_share(app, auth_headers, world, roles, coded):
    invoice, line = coded
    a = register_piece(line, weight=14.37, by='t', now=NOW)
    b = register_piece(line, weight=9.11, by='t', now=NOW)
    assert piece_wage(a) is None and piece_wage(b) is None
    _complete(auth_headers, world, invoice, line, 18.0)
    assert (piece_wage(a), piece_wage(b)) == (258.66, 163.98)
    wages = line_wages(line)
    assert round(sum(wages['pieces'].values()) + wages['rest'], 2) == wages['line'] == 540.0, 'law 5'


def test_with_no_rest_the_last_piece_takes_the_rounding(app, auth_headers, world, roles, coded):
    invoice, line = coded
    _complete(auth_headers, world, invoice, line, 12.333)
    pieces = [register_piece(line, weight=w, by='t', now=NOW) for w in (10.01, 10.01, 9.98)]
    wages = line_wages(line)
    assert wages['rest'] == 0.0 and wages['line'] == round(12.333 * 30.0, 2)
    assert round(sum(wages['pieces'].values()), 2) == wages['line'], 'law 5, to the halala'
    assert [piece_wage(p) for p in pieces[:2]] == [round(12.333 * 10.01, 2)] * 2


def test_bullion_wage_given_whole_is_divided_by_its_weight(app, auth_headers, world, roles, coded):
    """Bullion's wage is per gram too (the owner, 9 Nov 2026): its line's wage
    given whole, divided by its weight -- one line per bar size. Three 10 g
    bars, 100 riyals: 33.33, 33.33 and the last 33.34 -- 100 to the halala."""
    invoice, line = coded
    _complete(auth_headers, world, invoice, line, 100.0 / 30.0)
    bars = [register_piece(line, weight=10.0, by='t', now=NOW) for _ in range(3)]
    assert [piece_wage(b) for b in bars] == [33.33, 33.33, 33.34]
    wages = line_wages(line)
    assert wages['line'] == 100.0 and wages['rest'] == 0.0


def test_a_piece_whose_receipt_is_not_invoiced_is_not_sold(app, auth_headers, world, roles, coded):
    """Law 8 reads the wage itself: none yet, no sale."""
    _, line = coded
    piece = register_piece(line, weight=14.37, by='t', now=NOW)
    assert piece_wage(piece) is None
    with pytest.raises(PieceRefused) as refused:
        refuse_piece_sales('بيع', [{'item_id': piece.id, 'weight': 14.37, 'karat': 21}])
    assert refused.value.code == 'piece_wage_unknown'
