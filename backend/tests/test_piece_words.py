"""A piece's words: its name, description, model and size, edited and recorded (ADR-093 M3).

The owner (17 Nov 2026), on making the model optional: a piece coded
without a model is given one later. The laws:
  - the model and size are descriptions: edited from the piece's card, each
    edit recorded (what was, what is); the book facts stay;
  - by the station's laws: the model of its category and running, the size
    of its category's system and of the model's sizes when it names them;
  - the pieces' list filters by model and size -- and «none» for those without.

Run:
    python -m pytest tests/test_piece_words.py -v
"""
import json
from datetime import datetime

import pytest

from models import AuditLog, Category, db
from services.piece_models import create_model, update_model
from services.pieces import PieceRefused, piece_view, pieces_list, register_piece, update_piece_words
from tests.test_piece_model_station import sized  # noqa: F401
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401

TODAY = datetime(2026, 11, 17, 12, 0)


def _code(call):
    with pytest.raises(PieceRefused) as refused:
        call()
    return refused.value.code


def test_a_piece_given_its_model_and_size_later_recorded(sized):
    piece = register_piece(sized['line'], weight=21.0, by='t', now=NOW)
    changed = update_piece_words(piece, model_id=sized['model'].id, size_id=sized['sizes']['18'].id,
                                 description='لمعة عالية', by='owner', now=NOW)
    assert changed == {'description': [None, 'لمعة عالية'], 'model': [None, 'بنجرة الشمس'], 'size': [None, '18']}
    view = piece_view(piece)
    assert (view['model']['name'], view['size']['label']) == ('بنجرة الشمس', '18')
    record = AuditLog.query.filter_by(action='piece_words_edited', entity_id=piece.id).one()
    assert json.loads(record.details)['changed']['size'] == [None, '18'] and record.user_name == 'owner'
    assert update_piece_words(piece, size_id=sized['sizes']['18'].id, by='owner', now=NOW) == {}, 'nothing changed'
    assert piece.weight == 21.0


def test_by_the_stations_laws(sized):
    piece = register_piece(sized['line'], weight=10.0, by='t', now=NOW)
    model, sizes = sized['model'], sized['sizes']
    assert _code(lambda: update_piece_words(piece, model_id=model.id, size_id=sizes['19'].id, by='t',
                                            now=NOW)) == 'size_not_in_model'
    other = Category(name='خاتم اختبار 21', karat='21')
    db.session.add(other)
    db.session.flush()
    strange = create_model(category_id=other.id, name='خاتم', by='t', now=NOW)
    assert _code(lambda: update_piece_words(piece, model_id=strange.id, by='t', now=NOW)) == 'model_category_differs'
    update_model(model, now=NOW, is_active=False)
    assert _code(lambda: update_piece_words(piece, model_id=model.id, by='t', now=NOW)) == 'model_stopped'
    assert _code(lambda: update_piece_words(piece, name='  ', by='t', now=NOW)) == 'piece_name_empty'


def test_the_list_filters_by_model_and_size_and_by_none(sized):
    model, sizes = sized['model'], sized['sizes']
    sun = register_piece(sized['line'], weight=21.0, model_id=model.id, size_id=sizes['17'].id, by='t', now=NOW)
    plain = register_piece(sized['line'], weight=5.0, by='t', now=NOW)

    def codes(**kw):
        return {p['item_code'] for p in pieces_list(state='all', today=TODAY, **kw)['pieces']}
    assert codes(model_id=model.id) == {sun.item_code}
    assert plain.item_code in codes(model_id='none') and sun.item_code not in codes(model_id='none')
    assert codes(size_id=sizes['17'].id) == {sun.item_code}
    assert plain.item_code in codes(size_id='none')


def test_the_route_carries_it(sized, auth_headers):
    from flask import g
    from app import app as flask_app
    piece = register_piece(sized['line'], weight=9.0, by='t', now=NOW)
    client = flask_app.test_client()
    g.pop('current_user', None)
    done = client.patch(f'/api/pieces/{piece.id}', json={'model_id': sized['model'].id, 'weight': 1.0},
                        headers=auth_headers)
    assert done.status_code == 200, done.get_data(as_text=True)[:300]
    assert done.get_json()['piece']['model']['name'] == 'بنجرة الشمس' and done.get_json()['piece']['weight'] == 9.0
    g.pop('current_user', None)
    refused = client.patch(f'/api/pieces/{piece.id}', json={'size_id': sized['sizes']['19'].id},
                           headers=auth_headers)
    assert refused.status_code == 400 and refused.get_json()['error'] == 'size_not_in_model'
    g.pop('current_user', None)
    listed = client.get(f"/api/pieces?state=all&model_id={sized['model'].id}", headers=auth_headers).get_json()
    assert [p['item_code'] for p in listed['pieces']] == [piece.item_code]
