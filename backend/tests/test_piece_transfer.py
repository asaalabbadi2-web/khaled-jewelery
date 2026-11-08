"""A piece moves with the voucher that names it (ADR-087 R3.6).

A transfer moved weights: a piece's share stayed written on its source -- the
piece «in» the showroom it had left. The transfer voucher names its pieces
(their numbers): each in the stock and in the source; each karat's weight at
least its pieces'. Its entry posted, each piece's share is written out of the
source's line and into the target's -- under its number: the piece is where
it went, held as it was, its category's balance with it.

Run:
    python -m pytest tests/test_piece_transfer.py -v
"""
import uuid
from datetime import date

import pytest

from app import app as flask_app
from models import Category, JournalEntryLine, Settings, db
from services.pieces import open_coding, piece_held, piece_location, register_piece
from services.stock_ledger import allocate, category_held
from tests.test_melting_and_renewal_go_one_way import _holds, _safe
from tests.test_stock_count import NOW


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield


def _bangles():
    c = Category(name=f'بنجرة نقل {uuid.uuid4().hex[:6]} 21', karat='21', tracking='piece')
    db.session.add(c)
    db.session.flush()
    return c


def _pieces(box, category, *weights):
    _holds(box, 21, 60.0)
    line = JournalEntryLine.query.filter_by(account_id=box.account_id).order_by(JournalEntryLine.id.desc()).first()
    allocate(line, 21, category.id, 60.0, by='t', now=NOW)
    batch = open_coding(safe_box_id=box.id, category_id=category.id, weight=sum(weights), wage_per_gram=10,
                        by='t', now=NOW)
    return [register_piece(batch, weight=w, by='t', now=NOW) for w in weights]


def _sold(box, piece):
    from models import JournalEntry
    je = JournalEntry(entry_number=f'S-{uuid.uuid4().hex[:10]}', date=NOW, description='بيع', is_posted=True)
    db.session.add(je)
    db.session.flush()
    out = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, credit_21k=piece.weight)
    db.session.add(out)
    db.session.flush()
    allocate(out, 21, piece.category_id, -piece.weight, item_id=piece.id, by='t', now=NOW)


def _transfer(headers, source, target, grams, pieces=None):
    body = {'from_safe_box_id': source.id, 'to_safe_box_id': target.id, 'weights': {'21k': grams}}
    if pieces is not None:
        body['pieces'] = pieces
    return flask_app.test_client().post('/api/safe-boxes/transfer-voucher', headers=headers, json=body)


def test_a_piece_named_moves_with_its_category(auth_headers):
    showroom, other = _safe('showroom'), _safe('showroom', 'معرض الفرع')
    category = _bangles()
    a, b = _pieces(showroom, category, 14.37, 12.05)
    r = _transfer(auth_headers, showroom, other, 14.37, [a.item_code])
    assert r.status_code == 201, r.get_data(as_text=True)[:400]
    assert piece_location(a).id == other.id, 'the piece is where it went'
    assert piece_location(b).id == showroom.id
    assert piece_held(a.id) == 14.37, 'held as it was: still in the stock'
    assert category_held(other, 21, category.id) == 14.37
    assert category_held(showroom, 21, category.id) == round(60.0 - 14.37, 3)


def test_by_id_too_and_with_more_gold_than_its_pieces(auth_headers):
    showroom, custody = _safe('showroom'), _safe('custody')
    category = _bangles()
    a, = _pieces(showroom, category, 14.37)
    r = _transfer(auth_headers, showroom, custody, 20.0, [a.id])
    assert r.status_code == 201, r.get_data(as_text=True)[:400]
    assert piece_location(a).id == custody.id


@pytest.mark.parametrize('case', ['elsewhere', 'lighter', 'twice', 'unknown', 'sold'])
def test_the_pieces_laws(auth_headers, case):
    showroom, other = _safe('showroom'), _safe('showroom', 'معرض الفرع')
    category = _bangles()
    a, b = _pieces(showroom, category, 14.37, 12.05)
    if case == 'elsewhere':
        code = 'piece_not_here'
        _holds(other, 21, 20.0)
        r = _transfer(auth_headers, other, showroom, 14.37, [a.item_code])
    elif case == 'lighter':
        r, code = _transfer(auth_headers, showroom, other, 20.0, [a.item_code, b.item_code]), 'transfer_lighter_than_pieces'
    elif case == 'twice':
        r, code = _transfer(auth_headers, showroom, other, 30.0, [a.item_code, a.id]), 'piece_named_twice'
    elif case == 'unknown':
        r, code = _transfer(auth_headers, showroom, other, 10.0, ['KJ-999999']), 'piece_unknown'
    else:
        _sold(showroom, a)
        r, code = _transfer(auth_headers, showroom, other, 14.37, [a.item_code]), 'piece_sold'
    assert r.status_code == 400 and r.get_json()['error'] == code, (case, r.get_data(as_text=True)[:400])


def test_a_piece_is_looked_up_by_its_number_and_where_it_is(auth_headers):
    showroom = _safe('showroom')
    a, = _pieces(showroom, _bangles(), 14.37)
    c = flask_app.test_client()
    r = c.get(f'/api/pieces/lookup?code={a.item_code.lower()}', headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    body = r.get_json()
    assert (body['piece']['weight'], body['location']['id']) == (14.37, showroom.id)
    assert c.get('/api/pieces/lookup?code=KJ-999999', headers=auth_headers).status_code == 404


def test_pieces_are_not_moved_unnamed(auth_headers):
    """What stays of a karat covers the pieces left: 60 g held, 26.42 g of it
    pieces; 40 g moved unnamed leaves 20 -- less than the pieces."""
    showroom, other = _safe('showroom'), _safe('showroom', 'معرض الفرع')
    a, b = _pieces(showroom, _bangles(), 14.37, 12.05)
    r = _transfer(auth_headers, showroom, other, 40.0)
    assert r.status_code == 400 and r.get_json()['error'] == 'pieces_left_unnamed', r.get_data(as_text=True)
    assert _transfer(auth_headers, showroom, other, 40.0, [a.item_code]).status_code == 201, 'named, it is'
    assert _transfer(auth_headers, showroom, other, 5.0).status_code == 201, 'gold that is not its pieces'


def test_a_catalogue_item_of_before_is_not_a_piece_left_behind(auth_headers):
    """An I- item names its allocations too (the 5 Nov copy: 117.27 g in the
    showroom): it is not a piece, and holds no transfer back."""
    from models import Item
    showroom, other = _safe('showroom'), _safe('showroom', 'معرض الفرع')
    category = _bangles()
    _holds(showroom, 21, 30.0)
    line = JournalEntryLine.query.filter_by(account_id=showroom.account_id).order_by(JournalEntryLine.id.desc()).first()
    old = Item(item_code=f'I-{uuid.uuid4().hex[:6]}', name='قديم', karat='21', weight=25.0, price=0.0)
    db.session.add(old)
    db.session.flush()
    allocate(line, 21, category.id, 25.0, item_id=old.id, by='t', now=NOW)
    assert _transfer(auth_headers, showroom, other, 28.0).status_code == 201
