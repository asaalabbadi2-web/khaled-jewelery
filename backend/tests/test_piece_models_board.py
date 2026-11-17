"""The models board and the sizes grid (ADR-093 M4; the owner, 17 Nov 2026).

What is in stock of each model, size by size -- what has run out shows --
and, the model being optional, the pieces with none in a row of their own.
The laws:
  - the models and «بلا موديل» add up to the category's pieces in stock, in
    count and in grams -- nothing hidden by a piece that has no model;
  - a model's named size with nothing in stock is said (missing);
  - a piece out of stock (sold) is not counted;
  - the grid: a size's pieces lightest first, with their place.

Run:
    python -m pytest tests/test_piece_models_board.py -v
"""
from datetime import datetime

from services.piece_models import create_model, models_board, stock_grid
from services.pieces import register_piece
from tests.test_piece_model_station import sized  # noqa: F401
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_pieces_list import _out
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _stock(sized, showroom):
    line, model, sizes = sized['line'], sized['model'], sized['sizes']
    a = register_piece(line, weight=11.35, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
    b = register_piece(line, weight=10.90, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
    sold = register_piece(line, weight=2.0, model_id=model.id, size_id=sizes['17'].id, by='t', now=NOW)
    loose = register_piece(line, weight=3.0, size_id=sizes['19'].id, by='t', now=NOW)
    bare = register_piece(line, weight=1.5, by='t', now=NOW)
    _out(sold, showroom, sized['invoice'], invoice_type='بيع', when=datetime(2026, 11, 16))
    return {'a': a, 'b': b, 'sold': sold, 'loose': loose, 'bare': bare}


def test_the_models_and_no_model_add_up_to_the_category(sized, showroom):
    _stock(sized, showroom)
    board = models_board(sized['category'].id)
    total = board['in_stock']
    models = sum(m['stock']['count'] for m in board['models']) + board['no_model']['count']
    grams = round(sum(m['stock']['weight'] for m in board['models']) + board['no_model']['weight'], 3)
    assert (models, grams) == (total['count'], total['weight']) == (4, 26.75), 'the sold piece is out'
    assert board['no_model']['count'] == 2
    assert board['in_models']['count'] + board['no_model']['count'] == total['count'], 'the screen adds nothing up'


def test_a_models_sizes_in_stock_and_what_has_run_out(sized, showroom):
    _stock(sized, showroom)
    create_model(category_id=sized['category'].id, name='بنجرة المفتول',
                 size_ids=[sized['sizes'][k].id for k in ('17', '19')], by='t', now=NOW)
    board = {m['name']: m for m in models_board(sized['category'].id)['models']}
    sun = board['بنجرة الشمس']
    assert [(r['size']['label'], r['count']) for r in sun['by_size']] == [('17', 0), ('18', 2)]
    assert sun['missing'] == ['17'], 'its 17 was sold: run out'
    assert (sun['by_size'][1]['lightest'], sun['by_size'][1]['heaviest']) == (10.9, 11.35)
    assert board['بنجرة المفتول']['missing'] == ['17', '19'] and board['بنجرة المفتول']['stock']['count'] == 0
    loose = models_board(sized['category'].id)['no_model']['by_size']
    assert [(r['size'] and r['size']['label'], r['count']) for r in loose] == [('19', 1), (None, 1)]


def test_the_grid_lightest_first_with_their_place(sized, showroom):
    pieces = _stock(sized, showroom)
    grid = stock_grid(model_id=sized['model'].id)
    eighteen = next(r for r in grid['by_size'] if r['size'] and r['size']['label'] == '18')
    assert [p['item_code'] for p in eighteen['pieces']] == [pieces['b'].item_code, pieces['a'].item_code]
    assert eighteen['pieces'][0]['location'] == {'id': showroom.id, 'name': showroom.name}
    none = stock_grid(category_id=sized['category'].id, model_id='none')
    assert none['model'] is None and none['stock']['count'] == 2


def test_the_routes_carry_it(sized, showroom, auth_headers):
    from flask import g
    from app import app as flask_app
    _stock(sized, showroom)
    client = flask_app.test_client()
    g.pop('current_user', None)
    board = client.get(f"/api/piece-models/board?category_id={sized['category'].id}", headers=auth_headers)
    assert board.status_code == 200 and board.get_json()['in_stock']['count'] == 4
    g.pop('current_user', None)
    grid = client.get(f"/api/piece-models/stock-grid?model_id={sized['model'].id}", headers=auth_headers)
    assert grid.status_code == 200 and grid.get_json()['stock']['count'] == 2
    g.pop('current_user', None)
    refused = client.get('/api/piece-models/board', headers=auth_headers)
    assert refused.status_code == 400 and refused.get_json()['error'] == 'model_category_required'
