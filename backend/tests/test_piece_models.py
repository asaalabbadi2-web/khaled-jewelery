"""Piece models: what a model's pieces share (ADR-093 M1; the owner, 17 Nov 2026).

Bangles of one model share their shape and wage and differ in weight and
size; a photo is required on the screens. The laws:
  - a model is of one category, never scrap; its name unique in it;
  - it comes in sizes of its category's size system only; a size a piece of
    it holds stays; a size a model comes in stays in its system, and the
    category keeps its system;
  - its category is fixed, and it is stopped not deleted, once a piece is of it;
  - its photo and thumbnail are files in the attachments' store, linked in
    its own transaction -- its sender's, both or neither -- never text in the
    books; a photo replaced stays stored; sent and seen by the items' rights;
    its expected wage a number, never below zero.

Run:
    python -m pytest tests/test_piece_models.py -v
"""
import datetime as dt
import io
import uuid

import pytest

from models import Category, Item, SizeSystemSize, db
from models import Attachment
from services.attachments import MODEL_PHOTO, MODEL_THUMBNAIL, SCRAP_GOLD_PHOTO, store
from services.piece_models import ModelRefused, create_model, delete_model, list_models, model_view, update_model
from tests.test_attachments import jpeg, png
from services.size_systems import SizeRefused, create_system, delete_size, set_category_system

NOW = dt.datetime(2026, 11, 17, 15, 0)


@pytest.fixture
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def fenced(app, db_fence, tmp_path, monkeypatch):
    monkeypatch.setenv('MEDIA_ROOT', str(tmp_path / 'media'))
    yield


def _pair(by='t', salt=b''):
    return (store(jpeg(1200, 900, salt=salt), role=MODEL_PHOTO, by=by, now=NOW).id,
            store(png(240, 180), role=MODEL_THUMBNAIL, by=by, now=NOW).id)


def _headers_for(*codes):
    from auth_decorators import generate_token
    from models import Permission, Role, User
    tag = uuid.uuid4().hex[:8]
    user = User(username=f'pm_{tag}', full_name='t', is_active=True, is_admin=False)
    user.set_password('x')
    role = Role(name=f'pm_role_{tag}', name_ar='دور', is_active=True)
    db.session.add_all([user, role])
    db.session.flush()
    for code in codes:
        perm = Permission.query.filter_by(code=code).first() or Permission(code=code, name=code, name_ar=code,
                                                                           category='items', is_active=True)
        db.session.add(perm)
        db.session.flush()
        role.permissions.append(perm)
    user.roles.append(role)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}, user.username


def _bangles(*sizes, scrap=False):
    system = create_system(name=f'مقاسات {uuid.uuid4().hex[:6]}', sizes=sizes or ('17', '18', '19'), by='t',
                           now=NOW)
    category = Category(name=f'بنجرة {uuid.uuid4().hex[:6]} 21', karat='21', is_scrap=scrap)
    db.session.add(category)
    db.session.flush()
    set_category_system(category, system.id)
    return category, {s.label: s for s in SizeSystemSize.query.filter_by(system_id=system.id)}


def _model(category, sizes=(), **kw):
    return create_model(category_id=category.id, name=kw.pop('name', 'بنجرة الشمس'),
                        size_ids=[s.id for s in sizes], by='t', now=NOW, **kw)


def _piece(category, model, size=None):
    p = Item(item_code=f'KJ-M{uuid.uuid4().hex[:6]}', name=model.name, karat='21', weight=21.0, price=0.0,
             category_id=category.id, model_id=model.id, size_id=size.id if size else None)
    db.session.add(p)
    db.session.flush()
    return p


def _code(call):
    with pytest.raises((ModelRefused, SizeRefused)) as refused:
        call()
    return refused.value.code


def test_a_model_of_its_category_in_its_sizes_in_order(fenced):
    category, sizes = _bangles()
    model = _model(category, [sizes['19'], sizes['17']], supplier_code=' SUP-A-118 ',
                   expected_wage_per_gram='٣٩,٥', has_stones=True)
    view = model_view(model)
    assert [s['label'] for s in view['sizes']] == ['17', '19'], 'in the system\'s order'
    assert (view['supplier_code'], view['expected_wage_per_gram'], view['has_stones']) == ('SUP-A-118', 39.5, True)
    assert view['category']['id'] == category.id and view['pieces'] == 0
    assert _code(lambda: _model(category, name='  بنجرة   الشمس ')) == 'model_name_taken'
    scrap, _ = _bangles(scrap=True)
    assert _code(lambda: _model(scrap)) == 'model_category_scrap'
    assert _code(lambda: _model(category, name='سالبة', expected_wage_per_gram='-1')) == 'model_wage_invalid'


def test_only_its_categorys_sizes(fenced):
    category, _ = _bangles()
    _, other = _bangles('2.2', '2.4')
    assert _code(lambda: _model(category, [other['2.2']])) == 'size_not_in_category'
    plain = Category(name=f'طقم {uuid.uuid4().hex[:6]} 21', karat='21')
    db.session.add(plain)
    db.session.flush()
    assert _code(lambda: _model(plain, [other['2.4']])) == 'size_not_in_category', 'no system, no sizes'
    assert model_view(_model(plain))['sizes'] == []


def test_its_photo_is_a_file_in_the_store_linked_with_it_and_never_text(fenced):
    category, _ = _bangles()
    photo, thumbnail = _pair()
    model = _model(category, photo_id=photo, thumbnail_id=thumbnail)
    view = model_view(model)
    assert (view['photo_id'], view['thumbnail_id'], view['has_photo']) == (photo, thumbnail, True)
    assert not any(isinstance(v, str) and v.startswith('data:') for v in view.values()), 'no photo as text'
    linked = {a.id: a for a in Attachment.query.filter(Attachment.id.in_([photo, thumbnail]))}
    assert {(a.entity_type, a.entity_id) for a in linked.values()} == {('piece_model', model.id)}
    new_photo, new_thumbnail = _pair(salt=b'2')
    update_model(model, now=NOW, by='t', photo_id=new_photo, thumbnail_id=new_thumbnail)
    assert model.photo_id == new_photo
    assert db.session.get(Attachment, photo).entity_id == model.id, 'the photo replaced stays stored'
    update_model(model, now=NOW, by='t', photo_id=None, thumbnail_id=None)
    assert model_view(model)['has_photo'] is False


def test_its_photo_its_senders_both_or_neither_of_its_kind(fenced):
    category, _ = _bangles()
    theirs = _pair(by='someone_else')
    assert _code(lambda: _model(category, photo_id=theirs[0], thumbnail_id=theirs[1])) == 'attachment_not_yours'
    photo, thumbnail = _pair()
    assert _code(lambda: _model(category, name='بلا مصغّرة', photo_id=photo)) == 'photo_invalid'
    gold = store(jpeg(salt=b'g'), role=SCRAP_GOLD_PHOTO, by='t', now=NOW).id
    assert _code(lambda: _model(category, name='صورة كسر', photo_id=gold, thumbnail_id=thumbnail)) == \
        'attachment_not_found', 'a scrap photo is not a model\'s'
    _model(category, name='الأول', photo_id=photo, thumbnail_id=thumbnail)
    assert _code(lambda: _model(category, name='الثاني', photo_id=photo, thumbnail_id=thumbnail)) == \
        'attachment_already_linked'


def test_a_models_photo_is_sent_and_seen_by_the_items_rights(fenced):
    from flask import g
    from app import app as flask_app
    items, _ = _headers_for('items.view', 'items.edit')
    invoices, _ = _headers_for('invoices.view', 'invoices.create')

    def upload(headers, role):
        g.pop('current_user', None)
        return flask_app.test_client().post('/api/attachments', headers=headers, content_type='multipart/form-data',
                                            data={'role': role, 'file': (io.BytesIO(jpeg(salt=role.encode())), 'p.jpg')})
    assert upload(items, MODEL_PHOTO).status_code == 201
    assert upload(invoices, MODEL_PHOTO).status_code == 403, 'the invoices\' right is not the items\''
    assert upload(items, SCRAP_GOLD_PHOTO).status_code == 403
    category, _ = _bangles()
    photo, thumbnail = _pair()
    _model(category, name='للعرض', photo_id=photo, thumbnail_id=thumbnail)
    g.pop('current_user', None)
    assert flask_app.test_client().get(f'/api/attachments/{photo}', headers=items).status_code == 200
    g.pop('current_user', None)
    assert flask_app.test_client().get(f'/api/attachments/{photo}', headers=invoices).status_code == 403


def test_what_a_piece_holds_stays(fenced):
    category, sizes = _bangles()
    model = _model(category, [sizes['17'], sizes['18']])
    _piece(category, model, sizes['18'])
    assert _code(lambda: update_model(model, now=NOW, size_ids=[sizes['17'].id])) == 'size_in_use'
    update_model(model, now=NOW, size_ids=[sizes['18'].id, sizes['19'].id])          # 17 held by none: out
    assert [s['label'] for s in model_view(model)['sizes']] == ['18', '19']
    other, _ = _bangles()
    assert _code(lambda: update_model(model, now=NOW, category_id=other.id)) == 'model_in_use'
    assert _code(lambda: delete_model(model)) == 'model_in_use'
    update_model(model, now=NOW, is_active=False)
    assert model.id not in {m['id'] for m in list_models(category_id=category.id)}
    assert model.id in {m['id'] for m in list_models(category_id=category.id, include_inactive=True)}
    unused = _model(category, name='بنجرة لم تُستعمل')
    delete_model(unused)


def test_a_size_a_model_comes_in_stays_in_its_system_and_the_category_keeps_its_system(fenced):
    category, sizes = _bangles()
    _model(category, [sizes['19']])
    assert _code(lambda: delete_size(sizes['19'])) == 'size_in_model'
    _, other = _bangles('2.2')
    new_system = other['2.2'].system_id
    assert _code(lambda: set_category_system(category, new_system)) == 'size_system_in_use'


def test_the_routes_carry_it(fenced, auth_headers):
    from flask import g
    from app import app as flask_app
    category, sizes = _bangles()
    client = flask_app.test_client()
    g.pop('current_user', None)
    sent = [client.post('/api/attachments', headers=auth_headers, content_type='multipart/form-data',
                        data={'role': role, 'file': (io.BytesIO(raw), 'p')}).get_json()['id']
            for role, raw in ((MODEL_PHOTO, jpeg(1200, 900)), (MODEL_THUMBNAIL, png(240, 180)))]
    g.pop('current_user', None)
    made = client.post('/api/piece-models', json={'category_id': category.id, 'name': 'بنجرة المفتول',
                                                   'size_ids': [sizes['18'].id], 'photo_id': sent[0],
                                                   'thumbnail_id': sent[1]}, headers=auth_headers)
    assert made.status_code == 201, made.get_data(as_text=True)[:300]
    model = made.get_json()
    assert (model['photo_id'], model['thumbnail_id']) == tuple(sent) and [s['label'] for s in model['sizes']] == ['18']
    g.pop('current_user', None)
    listed = client.get(f'/api/piece-models?category_id={category.id}', headers=auth_headers).get_json()
    assert [m['id'] for m in listed] == [model['id']] and listed[0]['thumbnail_id'] == sent[1]
    g.pop('current_user', None)
    taken = client.post('/api/piece-models', json={'category_id': category.id, 'name': 'بنجرة المفتول'},
                        headers=auth_headers)
    assert taken.status_code == 400 and taken.get_json()['error'] == 'model_name_taken'
    g.pop('current_user', None)
    stopped = client.patch(f"/api/piece-models/{model['id']}", json={'is_active': False}, headers=auth_headers)
    assert stopped.status_code == 200 and stopped.get_json()['is_active'] is False
