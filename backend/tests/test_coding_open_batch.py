"""Coding from the unclassified stock, piece by piece (ADR-087 amendment; the owner, 27 Nov 2026: «اعتمده»).

The owner decided on 13 Oct (ADR-045) that 2026's stock stays unclassified until the 31 Dec count --
no category count before it -- and on 19 Nov (ADR-087) that the pieces are coded before the count.
Coding took only a category's grams in its place: nearly all the showroom's gold is unclassified
(27 Nov: about 14.5 kg of 21 and 12.6 kg of 18), so almost nothing could be coded. Now:

1. a batch opened with no weight -- it grows with its pieces;
2. on opening, a category's balance below nothing in its place -- its sales since the allocation
   began came out of the unclassified stock -- is brought to nothing from the place's unclassified
   grams of its karat, said, and written on the batch;
3. each piece takes its weighed grams: its category's free grams first, up to their net, then the
   place's unclassified grams of its karat;
4. never more than the books hold there: a piece heavier than the category's free grams and the
   unclassified ones together is refused, in words;
5. no entry, no balance moved: the place's grams of each karat as they were -- only how they are
   classified;
6. ending the batch writes nothing; an ended batch takes no piece;
7. what stays unclassified is the 31 Dec count's.
A batch opened with a weight keeps its law (tests/test_coding_from_stock.py and the rest).

Run:
    python -m pytest tests/test_coding_open_batch.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from models import Category, JournalEntry, JournalEntryLine, Settings, StockLineAllocation, db
from services.pieces import PieceRefused, open_coding, pending_lines, register_piece, weigh
from services.stock_ledger import allocate, category_held
from tests.test_melting_and_renewal_go_one_way import _account, _holds, _safe
from tests.test_stock_count import NOW


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield


def _bangles():
    c = Category(name=f'بناجر مفتوحة {uuid.uuid4().hex[:6]} 21', karat='21', tracking='piece')
    db.session.add(c)
    db.session.flush()
    return c


def _sale(box, category, grams):
    """A sale since the allocation began: its grams out of the category, in its place."""
    other = _account('8', 'مقابل', type='Asset', tracks_weight=True)
    je = JournalEntry(entry_number=f'S-{uuid.uuid4().hex[:10]}', date=datetime(2026, 10, 20), description='بيع',
                      is_posted=True)
    db.session.add(je)
    db.session.flush()
    out = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, credit_21k=grams)
    db.session.add_all([out, JournalEntryLine(journal_entry_id=je.id, account_id=other.id, debit_21k=grams)])
    db.session.flush()
    allocate(out, 21, category.id, -grams, now=NOW, by='t')


def _bought(box, category, grams):
    """A purchase since the allocation began: its grams into the category, in its place."""
    _holds(box, 21, grams)
    line = JournalEntryLine.query.filter_by(account_id=box.account_id).order_by(JournalEntryLine.id.desc()).first()
    allocate(line, 21, category.id, grams, now=NOW, by='t')


def _unclassified(box, karat=21):
    from services.stock_ledger import unclassified_grams
    return unclassified_grams(box, karat)


def _place_balance(box, karat=21):
    from services.live_balances import live_balances_by_account_ids
    return round(float(live_balances_by_account_ids([box.account_id])[box.account_id].get(f'{karat}k') or 0), 3)


def test_a_batch_opens_with_no_weight_and_grows_with_its_pieces():
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)                                    # unclassified, as 2026's stock is
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    assert batch.weight is None and batch.ended_at is None
    a = register_piece(batch, weight=12.4, wage=10, by='t', now=NOW)
    b = register_piece(batch, weight=9.85, wage=10, by='t', now=NOW)
    assert (a.coding_id, b.coding_id) == (batch.id, batch.id)
    view = [v for v in pending_lines() if v.get('coding_id') == batch.id][0]
    assert (view['open_batch'], view['pieces'], view['pieces_weight']) == (True, 2, 22.25)
    assert view['rest'] == pytest.approx(100.0 - 22.25), 'what the place still holds of it to code'
    assert view['rest_closable'] is False, 'no rest to close: it declared no weight'


def test_a_categorys_sales_since_the_allocation_are_settled_from_the_unclassified_on_opening():
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)
    _sale(showroom, bangles, 8.0)                                  # sold out of the unclassified stock
    assert category_held(showroom, 21, bangles.id) == -8.0
    before = (_unclassified(showroom), _place_balance(showroom))
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    assert batch.settled_grams == 8.0, 'written on the batch'
    assert category_held(showroom, 21, bangles.id) == 0.0, 'brought to nothing'
    assert _unclassified(showroom) == pytest.approx(before[0] - 8.0)
    assert _place_balance(showroom) == before[1], 'the place holds what it held'
    again = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    assert not again.settled_grams, 'settled once: nothing below nothing now'


def test_a_piece_takes_its_categorys_free_grams_first_then_the_unclassified():
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)
    _bought(showroom, bangles, 5.0)                                # bought since: the category's own
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    unclassified = _unclassified(showroom)
    piece = register_piece(batch, weight=8.0, wage=10, by='t', now=NOW)
    mine = StockLineAllocation.query.filter_by(item_id=piece.id).all()
    assert round(sum(r.grams for r in mine), 3) == 8.0 and {r.category_id for r in mine} == {bangles.id}
    assert _unclassified(showroom) == pytest.approx(unclassified - 3.0), 'five its category\'s, three classified'
    assert category_held(showroom, 21, bangles.id) == 8.0


def test_a_categorys_free_grams_spent_by_its_sales_are_not_taken_twice():
    """Bought 5 since, sold 5 since: its free net is nothing -- a piece takes all from the unclassified,
    not the purchase's row the sale has spent."""
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)
    _bought(showroom, bangles, 5.0)
    _sale(showroom, bangles, 5.0)
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    assert not batch.settled_grams
    unclassified = _unclassified(showroom)
    register_piece(batch, weight=6.0, wage=10, by='t', now=NOW)
    assert _unclassified(showroom) == pytest.approx(unclassified - 6.0)
    assert category_held(showroom, 21, bangles.id) == 6.0, 'the vitrine\'s piece, nothing less'


def test_never_more_than_the_books_hold_there():
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 10.0)
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    with pytest.raises(PieceRefused) as heavy:
        weigh(batch, weight=12.0)
    assert heavy.value.code == 'piece_more_than_held' and 'غير مصنّف' in heavy.value.message
    with pytest.raises(PieceRefused):
        register_piece(batch, weight=12.0, wage=10, by='t', now=NOW)
    assert register_piece(batch, weight=10.0, wage=10, by='t', now=NOW).weight == 10.0, 'all of it, no more'


def test_the_settling_refused_when_the_unclassified_cannot_cover_the_sales():
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 3.0)
    _sale(showroom, bangles, 8.0)
    with pytest.raises(PieceRefused) as refused:
        open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    assert refused.value.code == 'coding_unclassified_short'


def test_a_piece_spreads_over_the_lines_that_hold_room_each_within_its_own():
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 6.0)
    _holds(showroom, 21, 6.0)
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    piece = register_piece(batch, weight=10.0, wage=10, by='t', now=NOW)
    rows = StockLineAllocation.query.filter_by(item_id=piece.id).all()
    assert len(rows) == 2 and round(sum(r.grams for r in rows), 3) == 10.0
    for r in rows:
        line = db.session.get(JournalEntryLine, r.journal_entry_line_id)
        allocated = sum(a.grams for a in StockLineAllocation.query.filter_by(journal_entry_line_id=line.id))
        assert allocated <= float(line.debit_21k) + 1e-6, 'no line allocated past its weight'


def test_no_entry_and_the_places_grams_as_they_were():
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)
    _sale(showroom, bangles, 4.0)
    entries, balance = JournalEntry.query.count(), _place_balance(showroom)
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    register_piece(batch, weight=12.0, wage=10, by='t', now=NOW)
    assert JournalEntry.query.count() == entries, 'no entry: classified, not moved'
    assert _place_balance(showroom) == balance


def test_ending_the_batch_writes_nothing_and_it_takes_no_piece_after():
    from services.pieces import end_coding
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)
    batch = open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=None, by='t', now=NOW)
    register_piece(batch, weight=12.0, wage=10, by='t', now=NOW)
    entries, allocations = JournalEntry.query.count(), StockLineAllocation.query.count()
    end_coding(batch, by='t', now=NOW)
    assert batch.ended_at == NOW and batch.ended_by == 't'
    assert (JournalEntry.query.count(), StockLineAllocation.query.count()) == (entries, allocations)
    assert not [v for v in pending_lines() if v.get('coding_id') == batch.id], 'off the station\'s list'
    with pytest.raises(PieceRefused) as ended:
        register_piece(batch, weight=5.0, wage=10, by='t', now=NOW)
    assert ended.value.code == 'coding_ended'
    with pytest.raises(PieceRefused):
        end_coding(batch, by='t', now=NOW)


def test_a_batch_with_a_weight_keeps_its_law():
    """Declared, it is bounded by its category's grams as before: the unclassified are not its."""
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)
    with pytest.raises(PieceRefused) as refused:
        open_coding(safe_box_id=showroom.id, category_id=bangles.id, weight=20.0, by='t', now=NOW)
    assert refused.value.code == 'coding_more_than_held'


def test_the_routes_open_without_a_weight_say_the_settling_and_end(app, auth_headers):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    client = flask_app.test_client()
    showroom, bangles = _safe('showroom'), _bangles()
    _holds(showroom, 21, 100.0)
    _sale(showroom, bangles, 8.0)
    db.session.flush()
    g.pop('current_user', None)
    room = client.get(f'/api/stock-codings/free?safe_box_id={showroom.id}&category_id={bangles.id}',
                      headers=auth_headers).get_json()
    assert (room['unclassified'], room['category_net']) == (pytest.approx(100.0), -8.0), 'before its settling'
    g.pop('current_user', None)
    r = client.post('/api/stock-codings', headers=auth_headers,
                    json={'safe_box_id': showroom.id, 'category_id': bangles.id})
    assert r.status_code == 201, r.get_data(as_text=True)
    line = r.get_json()['line']
    assert (line['open_batch'], line['settled_grams']) == (True, 8.0)
    g.pop('current_user', None)
    ended = client.post(f'/api/stock-codings/{line["coding_id"]}/end', headers=auth_headers)
    assert ended.status_code == 200, ended.get_data(as_text=True)
    assert ended.get_json()['line']['ended_at']
