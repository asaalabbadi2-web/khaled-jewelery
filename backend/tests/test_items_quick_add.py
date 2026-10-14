"""«إضافة سريعة» and «استنساخ» -- several pieces in one go (ADR-045 B).

Both buttons sent POST /items/quick-add (the clone opens the quick add filled
from an item) -- a route that did not exist: 404 from every button. It is
built on the one item creation (its code and barcode generated), and it is
where pieces enter (phase C). A piece's karat is its category's: manual entry
must not mistake one karat for another (the owner, 14 Oct 2026).

Run:
    python -m pytest tests/test_items_quick_add.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import Category, Item, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _category(karat='21'):
    c = Category(name=f'عقد ذهب {uuid.uuid4().hex[:6]} {karat}', karat=karat)
    db.session.add(c)
    db.session.flush()
    return c


def _post(headers, body):
    return flask_app.test_client().post('/api/items/quick-add', headers=headers, json=body)


def test_several_pieces_are_added_each_with_its_own_code_and_barcode(app, auth_headers):
    cat = _category()
    resp = _post(auth_headers, {'base_name': 'عقود فراشة', 'category_id': cat.id, 'karat': '21',
                                'wage_per_gram': 30, 'has_stones': False,
                                'pieces': [{'weight': 6.7, 'description': '', 'name': None},
                                           {'weight': 12.25, 'description': 'طويل', 'name': 'عقد فراشة كبير'}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    made = resp.get_json()['items']
    assert len(made) == 2 and len({m['item_code'] for m in made}) == 2 and len({m['barcode'] for m in made}) == 2
    items = [db.session.get(Item, m['id']) for m in made]
    assert [(i.name, i.weight, i.category_id, i.karat) for i in items] == [
        ('عقود فراشة', 6.7, cat.id, '21'), ('عقد فراشة كبير', 12.25, cat.id, '21')]
    assert [round(i.wage, 2) for i in items] == [201.0, 367.5], 'the wage per gram times the weight'
    assert all(i.count == 1 for i in items)


def test_a_piece_karat_other_than_its_category_is_refused(app, auth_headers):
    cat = _category('21')
    resp = _post(auth_headers, {'base_name': 'خواتم', 'category_id': cat.id, 'karat': '18', 'wage_per_gram': 10,
                                'pieces': [{'weight': 3.0}]})
    assert resp.status_code == 400
    assert Item.query.filter_by(name='خواتم', category_id=cat.id).count() == 0


@pytest.mark.parametrize('pieces', [[], [{'weight': 0}], [{'weight': -2}]])
def test_no_piece_or_a_weightless_one_is_refused(app, auth_headers, pieces):
    cat = _category()
    resp = _post(auth_headers, {'base_name': 'أساور', 'category_id': cat.id, 'karat': '21', 'pieces': pieces})
    assert resp.status_code == 400


def test_one_refused_piece_adds_none(app, auth_headers):
    cat = _category()
    before = Item.query.count()
    resp = _post(auth_headers, {'base_name': 'أساور', 'category_id': cat.id, 'karat': '21',
                                'pieces': [{'weight': 5.0}, {'weight': 0}]})
    assert resp.status_code == 400 and Item.query.count() == before


def test_an_item_with_no_wage_is_added(app, auth_headers):
    """An empty wage reached the float column as '' and the insert failed."""
    resp = flask_app.test_client().post('/api/items', headers=auth_headers,
                                        json={'name': f'قطعة {uuid.uuid4().hex[:6]}', 'karat': '21', 'weight': 3})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert db.session.get(Item, resp.get_json()['id']).wage is None
