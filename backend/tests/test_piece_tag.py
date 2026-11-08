"""A piece's RFID tag (ADR-087 R3.7, §7; ADR-085 law 2; law 6).

- Its value by default is the number's: 4B4A, then the number's digits
  padded to twenty -- 24 hexadecimal characters (EPC-96); the number is read
  back from it.
- A piece has one active tag at a time; an active value is never another's
  (law 6) -- the database's partial unique indexes, the service before them.
- A damaged tag is replaced: the old stopped with its reason, a new one
  mounted; the piece and its number are as they were.
- A reader's value finds its piece, by the active tag.

Run:
    python -m pytest tests/test_piece_tag.py -v
"""
import uuid
from datetime import date

import pytest
from sqlalchemy.exc import IntegrityError

from models import Category, JournalEntryLine, PieceTag, Settings, db
from services.pieces import (PieceRefused, active_tag, epc_of, mount_tag, number_of_epc, open_coding,
                             piece_by_tag, register_piece, replace_tag)
from services.stock_ledger import allocate
from tests.test_melting_and_renewal_go_one_way import _holds, _safe
from tests.test_stock_count import NOW


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield


def _pieces(*weights):
    box = _safe('showroom')
    category = Category(name=f'بنجرة رقاقة {uuid.uuid4().hex[:6]} 21', karat='21', tracking='piece')
    db.session.add(category)
    db.session.flush()
    _holds(box, 21, 60.0)
    line = JournalEntryLine.query.filter_by(account_id=box.account_id).order_by(JournalEntryLine.id.desc()).first()
    allocate(line, 21, category.id, 60.0, by='t', now=NOW)
    batch = open_coding(safe_box_id=box.id, category_id=category.id, weight=sum(weights), wage_per_gram=10,
                        by='t', now=NOW)
    return [register_piece(batch, weight=w, by='t', now=NOW) for w in weights]


def test_the_value_is_the_numbers():
    assert epc_of('KJ-000124') == '4B4A00000000000000000124'
    assert len(epc_of('KJ-000124')) == 24
    assert number_of_epc('4B4A00000000000000000124') == 'KJ-000124'
    assert number_of_epc('4b4a00000000000000000124') == 'KJ-000124'
    assert number_of_epc('E2003412012345678901ABCD') is None, 'not ours'


def test_mounted_by_default_from_the_number_and_found_by_it(auth_headers):
    a, = _pieces(14.37)
    tag = mount_tag(a, by='t', now=NOW)
    assert (tag.value, tag.technology) == (epc_of(a.item_code), 'uhf_epc96')
    assert active_tag(a).id == tag.id
    assert piece_by_tag(tag.value.lower()).id == a.id


def test_one_active_tag_a_piece_and_an_active_value_is_not_another_s(auth_headers):
    a, b = _pieces(14.37, 12.05)
    mount_tag(a, by='t', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        mount_tag(a, by='t', now=NOW)
    assert refused.value.code == 'piece_has_active_tag'
    with pytest.raises(PieceRefused) as refused:
        mount_tag(b, value=epc_of(a.item_code), by='t', now=NOW)
    assert refused.value.code == 'tag_in_use'
    with pytest.raises(PieceRefused) as refused:
        mount_tag(b, value='not-hex', by='t', now=NOW)
    assert refused.value.code == 'tag_value_invalid'


def test_the_database_holds_law_6_too(auth_headers):
    a, b = _pieces(14.37, 12.05)
    mount_tag(a, by='t', now=NOW)
    with pytest.raises(IntegrityError):
        with db.session.begin_nested():
            db.session.add(PieceTag(item_id=b.id, value=epc_of(a.item_code), mounted_at=NOW))
            db.session.flush()


def test_a_damaged_tag_is_replaced_the_piece_as_it_was(auth_headers):
    a, = _pieces(14.37)
    old = mount_tag(a, by='t', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        replace_tag(a, reason='', by='t', now=NOW)
    assert refused.value.code == 'tag_reason_required'
    new = replace_tag(a, reason='تلفت عند التعليق', by='t', now=NOW)
    db.session.refresh(old)
    assert old.stopped_at is not None and old.stop_reason == 'تلفت عند التعليق'
    assert active_tag(a).id == new.id and new.value == epc_of(a.item_code)
    assert a.item_code.startswith('KJ-'), 'the number as it was'
    assert piece_by_tag(new.value).id == a.id


def test_the_routes(app, auth_headers):
    a, = _pieces(14.37)
    c = app.test_client()
    r = c.post(f'/api/pieces/{a.id}/tag', headers=auth_headers, json={})
    assert r.status_code == 201 and r.get_json()['tag']['value'] == epc_of(a.item_code), r.get_data(as_text=True)
    r = c.post(f'/api/pieces/{a.id}/tag', headers=auth_headers, json={})
    assert r.status_code == 400 and r.get_json()['error'] == 'piece_has_active_tag'
    r = c.post(f'/api/pieces/{a.id}/tag/replace', headers=auth_headers, json={'reason': 'تلفت'})
    assert r.status_code == 201, r.get_data(as_text=True)
    r = c.get(f'/api/pieces/by-tag/{epc_of(a.item_code)}', headers=auth_headers)
    assert r.status_code == 200 and r.get_json()['piece']['item_code'] == a.item_code
    assert r.get_json()['piece']['tag'] == epc_of(a.item_code)
    assert c.get('/api/pieces/by-tag/4B4A00000000000000999999', headers=auth_headers).status_code == 404
