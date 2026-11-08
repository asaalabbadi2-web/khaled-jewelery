"""Receiving alone makes a piece (ADR-087 §5, law 3; R3.3).

The item table is the piece's. Its other writers close:
- the invoice's inline creation (create_inline) -- gone, refused on any invoice;
- the catalogue's «إضافة صنف» (POST /items) and «إضافة سريعة» (POST
  /items/quick-add) -- refused while receiving is on (2027); in 2026, with no
  receiving, they stand as they are until the sunset (R6);
- a piece's book facts -- its number, weight, stones, karat, category, count --
  are not edited from the catalogue (PUT /items/<id>: its name and description
  are), and a piece is not deleted: its allocations in the books name it.
A ratchet holds the one writer: `Item(` is built in services/pieces.py, and in
routes/catalog.py's _new_item only (the catalogue before receiving, and the
scrap purchase's item names -- not pieces).

Run:
    python -m pytest tests/test_piece_one_writer.py -v
"""
import ast
import pathlib
from datetime import date

import pytest

from models import Item, Settings, db
from services.pieces import register_piece
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401

BACKEND = pathlib.Path(__file__).resolve().parents[1]


def _client(app):
    return app.test_client()


@pytest.fixture
def receiving(app):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield
    Settings.query.first().receiving_from = None
    db.session.flush()


def _piece(auth_headers, world, showroom, bangles_by_the_piece):
    _, line = _received(auth_headers, world, 20.0)
    bangles_by_the_piece(line)
    return register_piece(line, weight=14.37, by='t', now=NOW)


# ── the catalogue's two writers ─────────────────────────────────────────────

def test_receiving_on_the_catalogue_does_not_add_an_item(app, auth_headers, receiving):
    before = Item.query.count()
    r = _client(app).post('/api/items', headers=auth_headers, json={'name': 'بنجرة', 'karat': '21', 'weight': 10})
    assert r.status_code == 400 and r.get_json()['error'] == 'piece_born_on_receiving', r.get_data(as_text=True)
    r = _client(app).post('/api/items/quick-add', headers=auth_headers,
                          json={'base_name': 'بناجر', 'karat': '21', 'wage_per_gram': 10,
                                'pieces': [{'weight': 10}, {'weight': 12}]})
    assert r.status_code == 400 and r.get_json()['error'] == 'piece_born_on_receiving', r.get_data(as_text=True)
    assert Item.query.count() == before


def test_receiving_off_the_catalogue_adds_as_it_did(app, auth_headers):
    assert Settings.query.first().receiving_from is None
    r = _client(app).post('/api/items', headers=auth_headers, json={'name': 'صنف 2026', 'karat': '21', 'weight': 5})
    assert r.status_code == 201, r.get_data(as_text=True)


def test_the_scrap_names_are_not_pieces_and_stand(app, auth_headers, receiving):
    from models import Category
    from services.categories import scrap_category
    if scrap_category('21') is None:
        db.session.add(Category(name='كسر عيار 21 (اختبار)', karat='21', is_scrap=True))
        db.session.flush()
    r = _client(app).post('/api/purchase-items', headers=auth_headers, json={'name': 'كسر خواتم', 'karat': '21'})
    assert r.status_code == 201, r.get_data(as_text=True)


# ── the invoice's inline creation ───────────────────────────────────────────

@pytest.mark.parametrize('invoice_type', ['بيع', 'شراء من عميل', 'مرتجع شراء'])
def test_no_invoice_makes_an_item(app, auth_headers, invoice_type):
    before = Item.query.count()
    r = _client(app).post('/api/invoices', headers=auth_headers, json={
        'invoice_type': invoice_type, 'date': '2026-11-09T10:00:00',
        'items': [{'create_inline': True, 'name': 'قطعة', 'karat': 21, 'weight': 5.0}]})
    assert r.status_code == 400 and r.get_json()['error'] == 'piece_born_on_receiving', r.get_data(as_text=True)
    assert Item.query.count() == before


# ── a piece's facts and its life ────────────────────────────────────────────

def test_a_piece_name_is_edited_its_facts_are_not(app, auth_headers, world, roles, showroom,
                                                    bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    r = _client(app).put(f'/api/items/{piece.id}', headers=auth_headers,
                         json={'name': 'بنجرة مخرّمة', 'description': 'نقشة', 'weight': piece.weight,
                               'karat': piece.karat, 'barcode': piece.barcode})
    assert r.status_code == 200, r.get_data(as_text=True)
    db.session.refresh(piece)
    assert (piece.name, piece.description) == ('بنجرة مخرّمة', 'نقشة')
    for change in ({'weight': 15.0}, {'karat': '18'}, {'category_id': None}, {'barcode': 'X-1'},
                   {'stock': 3}, {'count': 2}):
        r = _client(app).put(f'/api/items/{piece.id}', headers=auth_headers, json=change)
        assert r.status_code == 400 and r.get_json()['error'] == 'piece_fixed', (change, r.get_data(as_text=True))
    db.session.refresh(piece)
    assert (round(piece.weight, 3), piece.karat, piece.barcode) == (14.37, '21', piece.item_code)


def test_a_piece_is_not_deleted(app, auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    r = _client(app).delete(f'/api/items/{piece.id}', headers=auth_headers)
    assert r.status_code == 400 and r.get_json()['error'] == 'piece_not_deleted', r.get_data(as_text=True)
    assert db.session.get(Item, piece.id) is not None


# ── the ratchet ─────────────────────────────────────────────────────────────

# Where `Item(` may be built, and why -- one line each.
ITEM_BUILT_IN = {
    'services/pieces.py': 'register_piece -- the one writer of a piece (ADR-087 §5)',
    'routes/catalog.py': '_new_item -- the catalogue before receiving (until R6) and the scrap names, not pieces',
}


def test_an_item_is_built_in_its_writers_only():
    found = {}
    for path in BACKEND.rglob('*.py'):
        rel = path.relative_to(BACKEND).as_posix()
        if rel.startswith(('tests/', 'migrations/', 'venv/', '.venv/')) or '/site-packages/' in rel:
            continue
        tree = ast.parse(path.read_text(encoding='utf-8'), filename=rel)
        calls = [n.lineno for n in ast.walk(tree)
                 if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'Item']
        if calls:
            found[rel] = calls
    assert set(found) == set(ITEM_BUILT_IN), f'Item( built outside its writers: {found}'
    assert all(len(lines) == 1 for lines in found.values()), f'one construction each: {found}'


def test_an_item_whose_wage_was_never_set_is_saved(app, auth_headers):
    """str(None) reached the float columns: an item with no wage failed to save
    on any edit. An empty number stays NULL; the price 0."""
    item = Item(item_code=f'T-{NOW:%H%M%S%f}'[:20], name='صنف بلا أجرة', karat='21', weight=4.0, price=0.0)
    db.session.add(item)
    db.session.flush()
    r = _client(app).put(f'/api/items/{item.id}', headers=auth_headers, json={'name': 'صنف معدَّل', 'price': ''})
    assert r.status_code == 200, r.get_data(as_text=True)
    db.session.refresh(item)
    assert (item.name, item.wage, item.price, item.weight) == ('صنف معدَّل', None, 0.0, 4.0)
