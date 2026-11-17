"""The station by the model and the size (ADR-093 M2; the owner, 17 Nov 2026).

A received line of bangles is coded piece by piece: the model chosen once,
each piece its size and its weight. The laws:
  - the model is of the line's category and running; the size of its
    category's size system, and of the model's sizes when it names them;
  - both optional: a piece with neither is coded as before;
  - the piece is named after its model;
  - the model's expected wage is compared with the invoice's -- a warning,
    never a refusal -- and the piece's wage stays its invoice's (ADR-087 §6).

Run:
    python -m pytest tests/test_piece_model_station.py -v
"""
import uuid

import pytest

from models import Category, SizeSystemSize, db
from services.piece_models import create_model, update_model
from services.pieces import (WAGE_AWAITING, WAGE_DIFFERS, WAGE_NO_EXPECTED, WAGE_SAME, PieceRefused, piece_view,
                             piece_wage, register_piece, wage_check)
from services.size_systems import create_system, set_category_system
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_station import _complete
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


@pytest.fixture
def sized(world, auth_headers, showroom, bangles_by_the_piece):
    """A received line of bangles by the piece, their category on a size system, one model in 17 and 18."""
    invoice, line = _received(auth_headers, world, 30.0)
    category = bangles_by_the_piece(line)
    system = create_system(name=f'مقاسات {uuid.uuid4().hex[:6]}', sizes=('17', '18', '19'), by='t', now=NOW)
    set_category_system(category, system.id)
    sizes = {s.label: s for s in SizeSystemSize.query.filter_by(system_id=system.id)}
    model = create_model(category_id=category.id, name='بنجرة الشمس', expected_wage_per_gram='39',
                         size_ids=[sizes['17'].id, sizes['18'].id], by='t', now=NOW)
    return {'invoice': invoice, 'line': line, 'category': category, 'sizes': sizes, 'model': model}


def _refused(call):
    with pytest.raises(PieceRefused) as refused:
        call()
    return refused.value.code


def test_a_piece_of_its_model_in_its_size_named_after_it(sized):
    piece = register_piece(sized['line'], weight=21.35, model_id=sized['model'].id, size_id=sized['sizes']['18'].id,
                           by='t', now=NOW)
    view = piece_view(piece)
    assert view['model'] == {'id': sized['model'].id, 'name': 'بنجرة الشمس'}
    assert view['size'] == {'id': sized['sizes']['18'].id, 'label': '18'}
    assert piece.name == 'بنجرة الشمس'
    plain = register_piece(sized['line'], weight=5.0, by='t', now=NOW)
    assert (piece_view(plain)['model'], piece_view(plain)['size']) == (None, None), 'both optional'
    assert plain.name == sized['category'].name
    alone = register_piece(sized['line'], weight=2.0, size_id=sized['sizes']['19'].id, by='t', now=NOW)
    assert piece_view(alone)['size']['label'] == '19', 'a size with no model: its category\'s system'


def test_the_model_and_the_size_are_its_categorys(sized, world):
    line, sizes = sized['line'], sized['sizes']
    assert _refused(lambda: register_piece(line, weight=3.0, model_id=sized['model'].id, size_id=sizes['19'].id,
                                           by='t', now=NOW)) == 'size_not_in_model'
    other_system = create_system(name=f'مقاسات {uuid.uuid4().hex[:6]}', sizes=('2.2',), by='t', now=NOW)
    foreign = SizeSystemSize.query.filter_by(system_id=other_system.id).one()
    assert _refused(lambda: register_piece(line, weight=3.0, size_id=foreign.id, by='t',
                                           now=NOW)) == 'size_not_in_category'
    other = Category(name=f'خاتم {uuid.uuid4().hex[:6]} 21', karat='21')
    db.session.add(other)
    db.session.flush()
    strange = create_model(category_id=other.id, name='خاتم', by='t', now=NOW)
    assert _refused(lambda: register_piece(line, weight=3.0, model_id=strange.id, by='t',
                                           now=NOW)) == 'model_category_differs'
    update_model(sized['model'], now=NOW, is_active=False)
    assert _refused(lambda: register_piece(line, weight=3.0, model_id=sized['model'].id, by='t',
                                           now=NOW)) == 'model_stopped'


def test_the_expected_wage_warns_and_the_piece_keeps_its_invoices(sized, auth_headers, world):
    line, model = sized['line'], sized['model']
    assert wage_check(line, model)['state'] == WAGE_AWAITING, 'the invoice not yet completed'
    piece = register_piece(line, weight=10.0, model_id=model.id, size_id=sized['sizes']['17'].id, by='t', now=NOW)
    _complete(auth_headers, world, sized['invoice'], line, 41.0)
    check = wage_check(line, model)
    assert check == {'state': WAGE_DIFFERS, 'invoice_per_gram': 41.0, 'expected_per_gram': 39.0}
    assert piece_wage(piece) == 410.0, 'the invoice\'s wage, never the model\'s'
    update_model(model, now=NOW, expected_wage_per_gram='41')
    assert wage_check(line, model)['state'] == WAGE_SAME
    update_model(model, now=NOW, expected_wage_per_gram=None)
    assert wage_check(line, model)['state'] == WAGE_NO_EXPECTED


def test_the_routes_carry_it(sized, auth_headers):
    from flask import g
    from app import app as flask_app
    client = flask_app.test_client()
    g.pop('current_user', None)
    made = client.post('/api/pieces', json={'line_id': sized['line'].id, 'weight': 20.9,
                                            'model_id': sized['model'].id, 'size_id': sized['sizes']['18'].id},
                       headers=auth_headers)
    assert made.status_code == 201, made.get_data(as_text=True)[:300]
    body = made.get_json()
    assert body['piece']['size']['label'] == '18' and body['line']['size_system_id'] == sized['category'].size_system_id
    g.pop('current_user', None)
    refused = client.post('/api/pieces', json={'line_id': sized['line'].id, 'weight': 2.0,
                                               'model_id': sized['model'].id, 'size_id': sized['sizes']['19'].id},
                          headers=auth_headers)
    assert refused.status_code == 400 and refused.get_json()['error'] == 'size_not_in_model'
    g.pop('current_user', None)
    check = client.get(f"/api/pieces/wage-check?line_id={sized['line'].id}&model_id={sized['model'].id}",
                       headers=auth_headers)
    assert check.status_code == 200 and check.get_json()['state'] == WAGE_AWAITING
