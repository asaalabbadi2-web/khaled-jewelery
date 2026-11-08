"""«ترميز من المخزون الموجود» (ADR-087 R3.5): a location's stock coded piece by piece.

A batch: a stock location, a category tracked by the piece, the weight to
code, its wage per gram entered by hand (the owner, 9 Nov 2026). No entry --
the gold does not move: a piece takes its share of the category's grams the
location holds not yet pieced, outside the receipts (a receipt's grams are
its own lines', their wage its invoice's). A batch weighs no more than that,
less what open batches have yet to code; its pieces no more than it. Its
pieces' wage is known at once -- they are sold; law 5 to the halala.

Run:
    python -m pytest tests/test_stock_coding.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from models import Category, JournalEntry, JournalEntryLine, Settings, StockLineAllocation, db
from services.pieces import (PieceRefused, free_grams, line_wages, open_coding, piece_held, piece_wage,
                             refuse_piece_sales, register_piece)
from services.stock_ledger import allocate, category_held
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


@pytest.fixture
def receiving(app):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield
    Settings.query.first().receiving_from = None
    db.session.flush()


@pytest.fixture
def bangles(world):
    c = Category(name=f'بنجرة مخزون {uuid.uuid4().hex[:6]} 21', karat='21', tracking='piece')
    db.session.add(c)
    db.session.flush()
    return c


def _stock(safe, category, grams):
    """Gold the location already holds of the category -- as the opening puts it."""
    je = JournalEntry(entry_number=f'JE-O-{uuid.uuid4().hex[:8]}', date=datetime(2027, 1, 1), description='افتتاح',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=safe.account_id, description='افتتاح',
                            debit_21k=grams)
    db.session.add(line)
    db.session.flush()
    allocate(line, 21, category.id, grams, by='t', now=NOW)
    return line


def _open(safe, category, weight, wage=15.0):
    return open_coding(safe_box_id=safe.id, category_id=category.id, weight=weight, wage_per_gram=wage,
                       note='بناجر المعرض', by='t', now=NOW)


def _code(batch):
    try:
        return open_coding(**batch)
    except PieceRefused as refused:
        return refused.code


def test_a_batch_codes_the_stock_without_moving_it(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 50.0)
    held = category_held(showroom, 21, bangles.id)
    batch = _open(showroom, bangles, 40.0)
    a = register_piece(batch, weight=14.37, by='t', now=NOW)
    b = register_piece(batch, weight=12.05, by='t', now=NOW)
    assert category_held(showroom, 21, bangles.id) == held, 'the category holds what it held: nothing moved'
    assert (piece_held(a.id), piece_held(b.id)) == (14.37, 12.05)
    assert free_grams(showroom, 21, bangles.id) == round(50.0 - 14.37 - 12.05, 3)
    assert JournalEntry.query.filter(JournalEntry.description.like('%ترميز%')).count() == 0, 'no entry'


def test_its_pieces_wage_is_known_and_they_are_sold(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 30.0)
    batch = _open(showroom, bangles, 30.0, wage=12.333)
    pieces = [register_piece(batch, weight=w, by='t', now=NOW) for w in (10.01, 10.01, 9.98)]
    assert [piece_wage(p) for p in pieces[:2]] == [round(12.333 * 10.01, 2)] * 2
    wages = line_wages(batch)
    assert round(sum(wages['pieces'].values()), 2) == wages['line'] == round(12.333 * 30.0, 2), 'law 5'
    refuse_piece_sales('بيع', [{'item_id': pieces[0].id, 'weight': 10.01, 'karat': 21}])     # not refused


def test_a_batch_weighs_no_more_than_the_location_holds(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 30.0)
    with pytest.raises(PieceRefused) as refused:
        _open(showroom, bangles, 30.5)
    assert refused.value.code == 'coding_more_than_held'
    _open(showroom, bangles, 20.0)
    with pytest.raises(PieceRefused) as refused:
        _open(showroom, bangles, 10.5)
    assert refused.value.code == 'coding_more_than_held', 'what an open batch has yet to code is promised'
    _open(showroom, bangles, 10.0)


def test_its_pieces_weigh_no_more_than_it(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 50.0)
    batch = _open(showroom, bangles, 20.0)
    register_piece(batch, weight=14.0, by='t', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        register_piece(batch, weight=6.5, by='t', now=NOW)
    assert refused.value.code == 'piece_heavier_than_rest'


def test_a_receipts_grams_are_its_own(app, auth_headers, world, roles, showroom, receiving):
    """A receipt's line in the same location and category is coded under it,
    with its invoice's wage -- a batch does not take its grams."""
    _, line = _received(auth_headers, world, 30.0)
    category = db.session.get(Category, line.category_id)
    category.tracking = 'piece'
    db.session.flush()
    assert free_grams(showroom, 21, category.id) == 0.0
    with pytest.raises(PieceRefused) as refused:
        _open(showroom, category, 5.0)
    assert refused.value.code == 'coding_more_than_held'
    _stock(showroom, category, 8.0)
    batch = _open(showroom, category, 8.0)
    piece = register_piece(batch, weight=8.0, by='t', now=NOW)
    on_receipt = StockLineAllocation.query.filter_by(item_id=piece.id).all()
    assert all(db.session.get(JournalEntryLine, r.journal_entry_line_id).description == 'افتتاح'
               for r in on_receipt), 'its share is the opening stock, not the receipt'


def test_the_batch_laws(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 30.0)
    weights = Category(name=f'خواتم {uuid.uuid4().hex[:6]} 21', karat='21')
    db.session.add(weights)
    db.session.flush()
    base = dict(safe_box_id=showroom.id, category_id=bangles.id, weight=10.0, wage_per_gram=15.0, by='t', now=NOW)
    assert _code({**base, 'category_id': weights.id}) == 'piece_category_by_weight'
    assert _code({**base, 'wage_per_gram': None}) == 'coding_figures_invalid', 'the wage entered, by hand'
    assert _code({**base, 'wage_per_gram': -1}) == 'coding_figures_invalid'
    assert _code({**base, 'weight': 0}) == 'coding_figures_invalid'
    assert _code({**base, 'safe_box_id': 999999}) == 'coding_location_invalid'
    assert not isinstance(_code({**base, 'wage_per_gram': 0}), str), 'zero is a wage'


def test_before_receiving_works_no_batch(app, world, roles, showroom, bangles):
    _stock(showroom, bangles, 30.0)
    with pytest.raises(PieceRefused) as refused:
        _open(showroom, bangles, 10.0)
    assert refused.value.code == 'coding_not_open'


# ── the routes ──────────────────────────────────────────────────────────────

def test_the_station_opens_a_batch_and_codes_it(app, auth_headers, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 30.0)
    c = app.test_client()
    r = c.get(f'/api/stock-codings/free?safe_box_id={showroom.id}&category_id={bangles.id}', headers=auth_headers)
    assert r.status_code == 200 and r.get_json()['room'] == 30.0, r.get_data(as_text=True)
    r = c.post('/api/stock-codings', headers=auth_headers,
               json={'safe_box_id': showroom.id, 'category_id': bangles.id, 'weight': 25, 'wage_per_gram': 14})
    assert r.status_code == 201, r.get_data(as_text=True)
    batch = r.get_json()['line']
    assert (batch['kind'], batch['rest'], batch['safe_name']) == ('stock', 25.0, showroom.name)
    pending = c.get('/api/pieces/pending', headers=auth_headers).get_json()['lines']
    assert any(l['coding_id'] == batch['coding_id'] for l in pending)
    body = {'coding_id': batch['coding_id'], 'weight': 14.37, 'request_key': 'sc-1'}
    r1 = c.post('/api/pieces', headers=auth_headers, json=body)
    r2 = c.post('/api/pieces', headers=auth_headers, json=body)
    assert r1.status_code == 201 and r2.get_json()['already_saved'] is True, r1.get_data(as_text=True)
    piece = r1.get_json()['piece']
    assert piece['wage'] == round(14 * 14.37, 2) and piece['coding_id'] == batch['coding_id']
    assert r1.get_json()['line']['rest'] == 10.63
    r = c.get(f"/api/pieces/codings/{batch['coding_id']}", headers=auth_headers)
    assert r.status_code == 200 and [p['item_code'] for p in r.get_json()['pieces']] == [piece['item_code']]
