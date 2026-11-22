"""A composite piece split into its parts (ADR-099; the owner, 23 Nov 2026).

«طقم يحتوي على ٤ اجزاء عقد، حلق، خاتم واسواره ... ببطاقة واحدة باسم طقم،
اراد الزبون شراء العقد والحلق فقط»: the set is split, each part weighed on
its own («الباقي يسجل كل جزء منفرد»), the difference allowed 0.05 g («الفرق
المقبول 0.05»), by whoever is given the permission («الصلاحية تضبط»). One
test for each of services/piece_split.py's laws.

Run:
    python -m pytest tests/test_piece_split.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from models import (Category, Item, JournalEntry, JournalEntryLine, PieceSplit, PieceSplitPart, Settings,
                    StockLineAllocation, WageAllocation, db)
from permissions import effective_permissions
from services.books_invariants import PIECE_SPLIT_UNBALANCED, check_piece_splits
from services.piece_split import read, split_piece
from services.pieces import (PieceRefused, open_coding, out_of_stock, piece_held, piece_wage, refuse_piece_sales,
                             register_piece)
from services.stock_ledger import allocate, category_held
from services.wage_ledger import pools, spread, unallocated_lines
from tests.test_stock_count import NOW, _safe, _stock, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_wage_allocation import _hand_entry

SPLIT_AT = datetime(2026, 12, 5, 11, 30)


@pytest.fixture(autouse=True)
def coding(app, rollback_after_each):
    row = Settings.query.first()
    row.coding_from, row.wage_pools_from, row.piece_split_tolerance = date(2026, 1, 1), None, 0.05
    db.session.flush()
    yield


def _category(name, tracking='weight', karat='21', **fields):
    c = Category(name=f'{name} {uuid.uuid4().hex[:6]}', karat=karat, tracking=tracking, **fields)
    db.session.add(c)
    db.session.flush()
    return c


@pytest.fixture
def shop(app, roles):
    """A showroom holding one set of 40 g, its wage 1,200 -- and the parts' categories."""
    box = _safe()
    sets = _category('طقم', 'piece')
    _stock(box, 40.0, sets)
    batch = open_coding(safe_box_id=box.id, category_id=sets.id, weight=40.0, by='t', now=NOW)
    piece = register_piece(batch, weight=40.0, wage=1200.0, wage_whole=True, by='t', now=NOW)
    return {'box': box, 'set': piece, 'sets': sets,
            'necklaces': _category('عقود'), 'earrings': _category('حلق'), 'rings': _category('خواتم'),
            'bracelets': _category('أساور', 'piece')}


def _parts(shop, necklace=20.0, earrings=6.0, ring=4.0, bracelet=10.0, wages=None):
    weights = {'necklaces': necklace, 'earrings': earrings, 'rings': ring, 'bracelets': bracelet}
    return [{'category_id': shop[c].id, 'weight': w, **({'wage': wages[n]} if wages else {})}
            for n, (c, w) in enumerate(weights.items())]


def _split(shop, parts=None, reason='الزبون يريد العقد والحلق', **kw):
    return split_piece(shop['set'].id, parts if parts is not None else _parts(shop), reason=reason, by='t',
                       now=SPLIT_AT, **kw)


def _refused(call):
    with pytest.raises(PieceRefused) as refused:
        call()
    return refused.value.code


def _safe_lines(split, box):
    return [l for l in JournalEntryLine.query.filter_by(journal_entry_id=split.journal_entry_id).all()
            if l.account_id == box.account_id]


# ── 6 + 3: each part on its own, and no riyal moves ─────────────────────────

def test_a_set_is_split_each_part_on_its_own(app, shop):
    split = _split(shop)
    piece = shop['set']
    assert piece_held(piece.id) == 0.0, 'the set is no longer in the stock'
    held = {c: category_held(shop['box'], 21, shop[c].id) for c in ('necklaces', 'earrings', 'rings')}
    assert held == {'necklaces': 20.0, 'earrings': 6.0, 'rings': 4.0}, 'a part by weight: its category\'s grams'
    bracelet = Item.query.filter_by(split_part_id=split.parts[3].id).one()
    assert bracelet.item_code.startswith('KJ-') and bracelet.item_code != piece.item_code
    assert (round(bracelet.weight, 3), piece_held(bracelet.id), bracelet.category_id) == \
        (10.0, 10.0, shop['bracelets'].id), 'a part by the piece: a piece of its own'
    assert [Item.query.filter_by(split_part_id=p.id).count() for p in split.parts] == [0, 0, 0, 1]
    lines = JournalEntryLine.query.filter_by(journal_entry_id=split.journal_entry_id).all()
    assert len(lines) == 2 and {l.account_id for l in lines} == {shop['box'].account_id}
    assert all(not (l.cash_debit or l.cash_credit) for l in lines), 'no riyal'
    assert round(sum((l.debit_21k or 0) - (l.credit_21k or 0) for l in lines), 3) == 0.0
    entry = db.session.get(JournalEntry, split.journal_entry_id)
    assert (entry.date, entry.reference_type, entry.reference_id) == (SPLIT_AT, 'piece_split', piece.id), \
        'dated when it happened: the categories before it unchanged'


def test_a_part_is_one_of_two_at_least_with_its_category(app, shop):
    assert _refused(lambda: _split(shop, _parts(shop)[:1])) == 'split_parts_too_few'
    no_category = _parts(shop)
    no_category[0]['category_id'] = None
    assert _refused(lambda: _split(shop, no_category)) == 'split_part_category'
    scrap = _category('كسر', is_scrap=True)
    to_scrap = _parts(shop)
    to_scrap[0]['category_id'] = scrap.id
    assert _refused(lambda: _split(shop, to_scrap)) == 'split_part_category'
    assert _refused(lambda: _split(shop, reason=' ')) == 'split_reason_required'
    assert PieceSplit.query.count() == 0


# ── 1: the weight, within the difference allowed ────────────────────────────

def test_a_difference_within_the_allowed_is_a_counts_shortage(app, shop, roles):
    split = _split(shop, _parts(shop, necklace=19.97))                         # 39.97 of 40.00
    assert split.difference == -0.03
    shortage = JournalEntryLine.query.filter_by(journal_entry_id=split.journal_entry_id,
                                                account_id=roles['shortage_w'].id).one()
    assert round(shortage.debit_21k, 3) == 0.03, 'written, never hidden in a part'
    assert round(sum((l.debit_21k or 0) - (l.credit_21k or 0) for l in _safe_lines(split, shop['box'])), 3) == -0.03


def test_a_difference_over_is_a_counts_surplus(app, shop, roles):
    split = _split(shop, _parts(shop, necklace=20.04))
    surplus = JournalEntryLine.query.filter_by(journal_entry_id=split.journal_entry_id,
                                               account_id=roles['surplus_w'].id).one()
    assert round(surplus.credit_21k, 3) == 0.04


def test_a_difference_beyond_the_allowed_is_refused(app, shop):
    assert _refused(lambda: _split(shop, _parts(shop, necklace=19.90))) == 'split_weight_differs'
    assert _refused(lambda: _split(shop, _parts(shop, necklace=20.06))) == 'split_weight_differs'
    Settings.query.first().piece_split_tolerance = 0.10                      # policy: the setting's
    assert read(shop['set'], _parts(shop, necklace=19.92))['difference'] == -0.08


# ── 2: karat and place are the piece's ──────────────────────────────────────

def test_a_part_inherits_its_pieces_karat(app, shop):
    parts = _parts(shop)
    parts[0]['category_id'] = _category('عقود 18', karat='18').id
    assert _refused(lambda: _split(shop, parts)) == 'split_part_karat'


# ── 4: all or nothing ───────────────────────────────────────────────────────

def test_a_split_failing_midway_leaves_nothing(app, shop, monkeypatch):
    import services.piece_split as module

    def fails(*args, **kwargs):
        raise PieceRefused('piece_line_not_allocated', 'عطل')
    monkeypatch.setattr(module, 'register_piece', fails)
    entries = JournalEntry.query.count()
    try:
        with db.session.begin_nested():
            _split(shop)
    except PieceRefused:
        pass
    assert (PieceSplit.query.count(), PieceSplitPart.query.count(), JournalEntry.query.count()) == (0, 0, entries)
    assert piece_held(shop['set'].id) == 40.0, 'the set still in the stock'


# ── 5 + 9: the set's number and tag never again ─────────────────────────────

def test_a_split_piece_is_never_split_nor_sold_again(app, shop):
    _split(shop)
    piece = shop['set']
    went = out_of_stock(piece)
    assert (went['state'], went['words']) == ('split', 'ليست في المخزون — فُكِّكت 2026-12-05')
    assert _refused(lambda: _split(shop)) == 'split_already'
    assert _refused(lambda: refuse_piece_sales('بيع', [{'item_id': piece.id, 'weight': 40.0, 'wage': 30.0}])) \
        == 'piece_sold'


def test_a_set_is_sold_whole_by_its_tag_until_it_is_split(app, shop):
    refuse_piece_sales('بيع', [{'item_id': shop['set'].id, 'weight': 40.0, 'wage': 30.0}])   # not refused


# ── 7: the wage and the stones add up ───────────────────────────────────────

def test_the_wage_is_shared_by_weight_the_last_takes_the_rounding(app, shop):
    split = _split(shop, _parts(shop, necklace=13.33, earrings=13.33, ring=3.34, bracelet=10.0))
    wages = [p.wage for p in split.parts]
    assert wages == [399.9, 399.9, 100.2, 300.0] and round(sum(wages), 2) == 1200.0
    bracelet = Item.query.filter_by(split_part_id=split.parts[3].id).one()
    assert piece_wage(bracelet) == 300.0, 'the new piece sells at its share'


def test_a_written_wage_adds_up_to_the_pieces(app, shop):
    split = _split(shop, _parts(shop, wages=[700, 200, 100, 200]))
    assert [p.wage for p in split.parts] == [700.0, 200.0, 100.0, 200.0]


def test_a_wage_written_wrong_is_refused(app, shop):
    assert _refused(lambda: _split(shop, _parts(shop, wages=[700, 200, 100, 250]))) == 'split_wage_differs'
    partial = _parts(shop)
    partial[0]['wage'] = 700
    assert _refused(lambda: _split(shop, partial)) == 'split_wage_partial'


def test_the_stones_are_the_pieces(app, roles):
    box, sets = _safe(), _category('طقم فصوص', 'piece')
    _stock(box, 30.0, sets)
    batch = open_coding(safe_box_id=box.id, category_id=sets.id, weight=30.0, by='t', now=NOW)
    piece = register_piece(batch, weight=30.0, stones_weight=1.5, wage=600.0, wage_whole=True, by='t', now=NOW)
    a, b = _category('عقود'), _category('حلق')
    parts = [{'category_id': a.id, 'weight': 20.0, 'stones_weight': 1.0},
             {'category_id': b.id, 'weight': 10.0, 'stones_weight': 0.2}]
    assert _refused(lambda: split_piece(piece.id, parts, reason='بيع', by='t', now=SPLIT_AT)) == 'split_stones_differ'
    parts[1]['stones_weight'] = 0.5
    split = split_piece(piece.id, parts, reason='بيع', by='t', now=SPLIT_AT)
    assert [p.stones_weight for p in split.parts] == [1.0, 0.5]


# ── 8: only a piece in stock, its wage known ────────────────────────────────

def test_a_piece_not_in_stock_is_not_split(app, shop):
    je = JournalEntry(entry_number=f'JE-X-{uuid.uuid4().hex[:8]}', date=NOW, description='خرجت', entry_type='عادي',
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=shop['box'].account_id, credit_21k=40.0)
    db.session.add(line)
    db.session.flush()
    allocate(line, 21, shop['sets'].id, -40.0, item_id=shop['set'].id, by='t', now=NOW)
    assert _refused(lambda: _split(shop)) == 'split_piece_not_in_stock'


def test_a_piece_whose_wage_is_unknown_is_not_split(app, shop, monkeypatch):
    import services.piece_split as module
    monkeypatch.setattr(module, 'piece_wage', lambda piece: None)            # its receipt not yet invoiced
    assert _refused(lambda: _split(shop)) == 'split_wage_unknown'


def test_what_is_not_a_piece_is_not_split(app, shop):
    item = Item(item_code=f'I-{uuid.uuid4().hex[:6]}', name='صنف', price=0.0)
    db.session.add(item)
    db.session.flush()
    assert _refused(lambda: split_piece(item.id, _parts(shop), reason='x', by='t', now=SPLIT_AT)) \
        == 'split_not_a_piece'


# ── pressed twice, one split; kept as written ───────────────────────────────

def test_pressed_twice_one_split(app, shop):
    first = _split(shop, request_key='k-1')
    assert _split(shop, request_key='k-1').id == first.id
    assert PieceSplit.query.count() == 1


def test_a_split_is_kept_as_written(app, shop):
    split = _split(shop)
    split.parts[0].weight = 21.0
    with pytest.raises(ValueError):
        db.session.flush()
    db.session.rollback()


# ── from the wages' pools: the wage moves with its parts ────────────────────

def test_from_the_pools_the_wage_moves_with_its_parts(app, roles):
    Settings.query.first().wage_pools_from = date(2026, 1, 1)
    box, sets = _safe(), _category('طقم وعاء', 'piece')
    _stock(box, 40.0, sets)
    spread(_hand_entry(1200.0, day=NOW), [(21, sets.id, None, 1.0)], now=NOW, what='وعاء')   # 30 a gram
    batch = open_coding(safe_box_id=box.id, category_id=sets.id, weight=40.0, by='t', now=NOW)
    piece = register_piece(batch, weight=40.0, by='t', now=NOW)
    assert piece_wage(piece) == 1200.0
    necklaces, bracelets = _category('عقود'), _category('أساور', 'piece')
    split = split_piece(piece.id, [{'category_id': necklaces.id, 'weight': 30.0},
                                   {'category_id': bracelets.id, 'weight': 10.0}],
                        reason='بيع', by='t', now=SPLIT_AT)
    bracelet = Item.query.filter_by(split_part_id=split.parts[1].id).one()

    def own(item):
        return round(sum(a.riyals for a in WageAllocation.query.filter_by(item_id=item.id)), 2)
    assert (own(piece), own(bracelet)) == (0.0, 300.0), 'out of the set\'s own, into the bracelet\'s'
    assert pools().get((21, necklaces.id)) == {'riyals': 900.0, 'grams': 30.0}, 'a part by weight: its pool'
    assert not unallocated_lines()
    cash = [l for l in JournalEntryLine.query.filter_by(journal_entry_id=split.journal_entry_id)
            if l.cash_debit or l.cash_credit]
    assert round(sum((l.cash_debit or 0) - (l.cash_credit or 0) for l in cash), 2) == 0.0, 'no riyal moves'


# ── the nightly check, and who may ──────────────────────────────────────────

def test_the_nightly_check_sees_a_split_that_is_not_what_it_says(app, shop):
    split = _split(shop)
    assert [f for f in check_piece_splits() if f.subject_key == f'piece_split:{split.id}'] == []
    in_line = next(l for l in _safe_lines(split, shop['box']) if l.debit_21k)
    row = StockLineAllocation.query.filter_by(journal_entry_line_id=in_line.id,
                                              category_id=shop['necklaces'].id).one()
    db.session.execute(db.text('UPDATE piece_split_part SET weight = 25 WHERE id = :id'), {'id': split.parts[0].id})
    db.session.expire_all()
    found = [f for f in check_piece_splits() if f.subject_key == f'piece_split:{split.id}']
    assert found and found[0].kind == PIECE_SPLIT_UNBALANCED and found[0].detail['parts_weigh'] == 5.0
    assert row is not None


def test_the_manager_splits_and_others_when_given(app):
    assert 'items.split' in effective_permissions('manager', None)
    assert 'items.split' not in effective_permissions('employee', None)
    assert 'items.split' in effective_permissions('employee', {'items.split': True}), 'الصلاحية تضبط'
