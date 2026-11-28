"""A piece's coding undone, and a batch's (the owner, 28 Nov 2026: «ابدأ»).

A category switched to «بالقطعة» refuses a sale without a piece, and is refused back to weight
while a piece of it is held; a piece is never deleted -- the books name it. A category coded by
mistake, or a batch not finished before the shop opens, had no way back but selling. Now:

1. a piece of a stock batch, held, its coding undone: its grams go back to its category in its
   place under no number -- no entry, the place's grams as they were;
2. its adopted chip stopped, said so when read; its number kept in the record, said uncoded,
   never used again;
3. only a held piece of a stock batch -- not one sold, not a receipt's nor a split's, not one
   whose wage its pool gave it;
4. a reason, a name, the audit log; the manager's (items.delete);
5. a batch undone: each of its pieces still held undone, the batch ended;
6. none of the category held: back to weight, as ever.
The category's settling on opening stays: its sales did come out of that gold.

Run:
    python -m pytest tests/test_piece_uncode.py -v
"""
import pytest

from models import Item, JournalEntry, PieceTag, StockLineAllocation, db
from services.pieces import (PieceRefused, active_tag, epc_of, mount_tag, open_coding, piece_held, register_piece,
                             set_tracking)
from services.stock_ledger import category_held
from tests.test_coding_open_batch import _bangles, _place_balance, _behind_the_fence  # noqa: F401
from tests.test_melting_and_renewal_go_one_way import _holds, _safe
from tests.test_piece_transfer import _sold
from tests.test_stock_count import NOW


def _batch_with(*weights, held=100.0):
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, held)
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    pieces = [register_piece(batch, weight=w, wage=10, by='t', now=NOW) for w in weights]
    for p in pieces:
        mount_tag(p, by='t', now=NOW)
    return showroom, bangles, batch, pieces


def test_a_pieces_coding_undone_its_grams_back_to_its_category_no_entry():
    from services.pieces import uncode_piece
    showroom, bangles, _, [piece] = _batch_with(12.4)
    entries, balance = JournalEntry.query.count(), _place_balance(showroom)
    held = category_held(showroom, 21, bangles.id)
    uncode_piece(piece, reason='رُمّزت بالخطأ', by='manager', now=NOW)
    assert piece_held(piece.id) == 0.0, 'no longer a piece in the stock'
    assert category_held(showroom, 21, bangles.id) == held, 'its grams its category\'s, under no number'
    assert not StockLineAllocation.query.filter_by(item_id=piece.id).count()
    assert (JournalEntry.query.count(), _place_balance(showroom)) == (entries, balance), 'no entry'
    assert (piece.uncoded_at, piece.uncoded_by, piece.uncode_reason) == (NOW, 'manager', 'رُمّزت بالخطأ')
    assert db.session.get(Item, piece.id) is not None, 'its number kept in the record'


def test_its_chip_stopped_and_said_so_when_read():
    from services.pieces import tag_state, uncode_piece
    _, _, _, [piece] = _batch_with(12.4)
    uncode_piece(piece, reason='رُمّزت بالخطأ', by='manager', now=NOW)
    assert active_tag(piece) is None
    stopped = PieceTag.query.filter_by(item_id=piece.id).one()
    assert stopped.stopped_at == NOW and 'أُلغي ترميز' in stopped.stop_reason
    assert tag_state(epc_of(piece.item_code))['state'] == 'stopped'


def test_the_category_goes_back_to_weight_once_none_of_it_is_held():
    from services.pieces import uncode_piece
    _, bangles, _, [piece] = _batch_with(12.4)
    with pytest.raises(PieceRefused):
        set_tracking(bangles, tracking='weight')
    uncode_piece(piece, reason='رُمّزت بالخطأ', by='manager', now=NOW)
    set_tracking(bangles, tracking='weight')
    assert bangles.tracking == 'weight'


def test_only_a_held_piece_of_a_stock_batch_with_a_reason_once():
    from services.pieces import uncode_piece
    showroom, _, _, [a, b] = _batch_with(12.4, 9.0)
    with pytest.raises(PieceRefused) as no_reason:
        uncode_piece(a, reason='  ', by='manager', now=NOW)
    assert no_reason.value.code == 'uncode_reason_required'
    _sold(showroom, b)
    with pytest.raises(PieceRefused) as sold:
        uncode_piece(b, reason='x', by='manager', now=NOW)
    assert sold.value.code == 'piece_not_in_stock'
    uncode_piece(a, reason='x', by='manager', now=NOW)
    with pytest.raises(PieceRefused) as again:
        uncode_piece(a, reason='x', by='manager', now=NOW)
    assert again.value.code == 'piece_uncoded'


def test_an_uncoded_piece_is_not_sold_and_says_why():
    from services.pieces import out_of_stock, refuse_piece_sales, uncode_piece
    _, bangles, _, [piece] = _batch_with(12.4)
    uncode_piece(piece, reason='رُمّزت بالخطأ', by='manager', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        refuse_piece_sales('بيع', [{'item_id': piece.id, 'category_id': bangles.id, 'weight': 12.4}])
    assert refused.value.code == 'piece_uncoded'
    assert 'أُلغي ترميزها' in out_of_stock(piece)['words']


def test_a_weighed_batch_gets_back_the_grams_of_a_piece_undone():
    from services.pieces import batch_rest, uncode_piece
    from tests.test_coding_open_batch import _bought
    showroom, bangles = _safe('showroom'), _bangles()
    _bought(showroom, bangles, 30.0)
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=30.0, by='t', now=NOW)
    piece = register_piece(batch, weight=12.0, wage=10, by='t', now=NOW)
    assert batch_rest(batch) == 18.0
    uncode_piece(piece, reason='رُمّزت بالخطأ', by='manager', now=NOW)
    assert batch_rest(batch) == 30.0, 'its weight to code again'


def test_a_batch_undone_its_held_pieces_undone_its_sold_kept_the_batch_ended():
    from services.pieces import pending_lines, uncode_batch
    showroom, bangles, batch, [a, b, c] = _batch_with(12.4, 9.0, 7.5)
    _sold(showroom, c)
    entries = JournalEntry.query.count()
    undone = uncode_batch(batch, reason='لم يكتمل قبل الفتح', by='manager', now=NOW)
    assert {p.id for p in undone} == {a.id, b.id}, 'the sold one is a sale\'s'
    assert piece_held(a.id) == piece_held(b.id) == 0.0
    assert batch.ended_at == NOW
    assert not [v for v in pending_lines() if v.get('coding_id') == batch.id]
    assert JournalEntry.query.count() == entries
    set_tracking(bangles, tracking='weight')


def test_the_routes_are_the_managers(app, auth_headers):
    from flask import g
    from tests.test_count_return import _headers_for
    from tests.test_wage_treatment_follows_the_setting import flask_app
    client = flask_app.test_client()
    _, _, batch, [a, b] = _batch_with(12.4, 9.0)
    coder = _headers_for('items.create')
    g.pop('current_user', None)
    assert client.post(f'/api/pieces/{a.id}/uncode', headers=coder, json={'reason': 'x'}).status_code == 403
    g.pop('current_user', None)
    r = client.post(f'/api/pieces/{a.id}/uncode', headers=auth_headers, json={'reason': 'رُمّزت بالخطأ'})
    assert r.status_code == 200, r.get_data(as_text=True)
    assert r.get_json()['piece']['uncoded_at']
    g.pop('current_user', None)
    r = client.post(f'/api/stock-codings/{batch.id}/uncode', headers=auth_headers, json={'reason': 'لم يكتمل'})
    assert r.status_code == 200, r.get_data(as_text=True)
    assert r.get_json()['undone'] == 1 and r.get_json()['line']['ended_at']
