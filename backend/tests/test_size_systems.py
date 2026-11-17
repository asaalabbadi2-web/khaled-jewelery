"""Size systems: the sizes the categories share (ADR-093 M0; the owner, 17 Nov 2026).

«مقاسات البناجر عندنا تكون 17، 18، 19 وهكذا ... هناك عدة أنظمة للمقاسات» --
a supplier's other system «تحول إلى نظامنا المعتمد». The laws:
  - a size is text in one spelling: «١٨» is 18, «2,6» is 2.6, and «2.10» is
    not «2.1»; unique in its system, in its order;
  - a system is shared: two categories follow one; a category one or none;
  - a size a piece holds is not taken out; a spelling corrected reaches it;
  - a category whose pieces hold sizes keeps its system; a system a category
    follows is not deleted.

Run:
    python -m pytest tests/test_size_systems.py -v
"""
import datetime as dt
import uuid

import pytest

from models import Category, Item, SizeSystemSize, db
from services.size_systems import (SizeRefused, add_size, create_system, delete_size, delete_system,
                                   normalize_label, reorder, set_category_system, system_view, update_size)

NOW = dt.datetime(2026, 11, 17, 12, 0)


@pytest.fixture
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def fenced(app, db_fence):
    yield


def _system(*sizes, name=None):
    return create_system(name=name or f'مقاسات {uuid.uuid4().hex[:6]}', sizes=sizes, by='t', now=NOW)


def _category(karat='21'):
    c = Category(name=f'بنجرة {uuid.uuid4().hex[:6]} {karat}', karat=karat)
    db.session.add(c)
    db.session.flush()
    return c


def _piece(category, size):
    p = Item(item_code=f'KJ-T{uuid.uuid4().hex[:6]}', name='بنجرة', karat=category.karat, weight=21.0, price=0.0,
             category_id=category.id, size_id=size.id)
    db.session.add(p)
    db.session.flush()
    return p


def _labels(system):
    return [s['label'] for s in system_view(system)['sizes']]


def test_a_size_is_text_in_one_spelling():
    assert normalize_label('١٨') == '18'
    assert normalize_label(' 2,6 ') == normalize_label('2٫6') == '2.6'
    assert normalize_label('2.10') == '2.10' and normalize_label('2.10') != normalize_label('2.1')
    with pytest.raises(SizeRefused, match='اكتب المقاس'):
        normalize_label('  ')


def test_a_system_keeps_its_sizes_in_order_and_one_spelling_once(fenced):
    system = _system('17', '١٨', '19')
    assert _labels(system) == ['17', '18', '19']
    with pytest.raises(SizeRefused) as taken:
        add_size(system, label='18', by='t', now=NOW)
    assert taken.value.code == 'size_label_taken'
    both = _system('2.1', '2.10')
    assert _labels(both) == ['2.1', '2.10'], '«2.10» is not «2.1»'
    with pytest.raises(SizeRefused) as named:
        _system(name=system.name.upper())
    assert named.value.code == 'size_system_name_taken'


def test_a_size_goes_where_it_is_put_and_the_order_is_every_size_once(fenced):
    system = _system('17', '19')
    nineteen = SizeSystemSize.query.filter_by(system_id=system.id, label='19').one()
    add_size(system, label='18', before_id=nineteen.id, by='t', now=NOW)
    add_size(system, label='20', by='t', now=NOW)
    assert _labels(system) == ['17', '18', '19', '20']
    assert [s['position'] for s in system_view(system)['sizes']] == [1, 2, 3, 4]
    ids = [s['id'] for s in system_view(system)['sizes']]
    reorder(system, list(reversed(ids)))
    assert _labels(system) == ['20', '19', '18', '17']
    with pytest.raises(SizeRefused) as partial:
        reorder(system, ids[:2])
    assert partial.value.code == 'size_order_invalid'


def test_a_size_a_piece_holds_stays_and_its_spelling_corrected_reaches_the_piece(fenced):
    system = _system('17', '18')
    bangles = _category()
    set_category_system(bangles, system.id)
    eighteen = SizeSystemSize.query.filter_by(system_id=system.id, label='18').one()
    piece = _piece(bangles, eighteen)
    assert [s['pieces'] for s in system_view(system)['sizes']] == [0, 1]
    with pytest.raises(SizeRefused) as held:
        delete_size(eighteen)
    assert held.value.code == 'size_in_use'
    update_size(eighteen, label='١٨.5')
    assert db.session.get(SizeSystemSize, piece.size_id).label == '18.5'
    seventeen = SizeSystemSize.query.filter_by(system_id=system.id, label='17').one()
    delete_size(seventeen)
    assert _labels(system) == ['18.5'] and system_view(system)['sizes'][0]['position'] == 1


def test_categories_share_a_system_and_keep_it_while_their_pieces_hold_sizes(fenced):
    system, other = _system('17', '18'), _system('2.2', '2.4')
    of_21, of_18 = _category('21'), _category('18')
    set_category_system(of_21, system.id)
    set_category_system(of_18, system.id)
    assert {c['id'] for c in system_view(system)['categories']} == {of_21.id, of_18.id}
    _piece(of_21, SizeSystemSize.query.filter_by(system_id=system.id, label='17').one())
    with pytest.raises(SizeRefused) as kept:
        set_category_system(of_21, other.id)
    assert kept.value.code == 'size_system_in_use'
    set_category_system(of_18, other.id)                     # no piece of it holds a size
    assert of_18.size_system_id == other.id
    with pytest.raises(SizeRefused) as followed:
        delete_system(system)
    assert followed.value.code == 'size_system_followed'


def test_the_routes_carry_it(fenced, auth_headers):
    from flask import g
    from app import app as flask_app
    client = flask_app.test_client()
    g.pop('current_user', None)
    made = client.post('/api/size-systems', json={'name': f'مقاسات البناجر {uuid.uuid4().hex[:4]}',
                                                   'measurement_label': 'القطر الداخلي — مم',
                                                   'sizes': ['17', '18']}, headers=auth_headers)
    assert made.status_code == 201, made.get_data(as_text=True)[:300]
    system = made.get_json()
    assert [s['label'] for s in system['sizes']] == ['17', '18']
    g.pop('current_user', None)
    taken = client.post(f"/api/size-systems/{system['id']}/sizes", json={'label': '١٨'}, headers=auth_headers)
    assert taken.status_code == 400 and taken.get_json()['error'] == 'size_label_taken'
    g.pop('current_user', None)
    added = client.post(f"/api/size-systems/{system['id']}/sizes", json={'label': '19', 'measurement': '61,5'},
                        headers=auth_headers)
    assert added.status_code == 201 and added.get_json()['sizes'][-1]['measurement'] == 61.5
    category = _category()
    g.pop('current_user', None)
    put = client.put(f'/api/categories/{category.id}', json={'size_system_id': system['id']}, headers=auth_headers)
    assert put.status_code == 200 and put.get_json()['size_system_id'] == system['id']
    g.pop('current_user', None)
    listed = {s['id']: s for s in client.get('/api/size-systems', headers=auth_headers).get_json()}
    assert listed[system['id']]['categories'] == [{'id': category.id, 'name': category.name}]
