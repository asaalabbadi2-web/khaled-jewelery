"""A pool's wage moves with its goods (ADR-096 ت3; the owner, 20 Nov 2026).

ت2 found it: a piece coded in 2027 from a category with a pool carried its
wage, but took nothing out of the pool -- the average of what was left rose.
A receipt's piece did the same with its invoice's wage. From wage_pools_from on:
- a piece coded from the stock takes its pool's average (the owner: «متوسط
  الوعاء»), a wage written for it refused; the rest of the pool keeps its average;
- a receipt's piece takes its share of its invoice's wage -- at its coding
  once the invoice is completed, at the completion when coded before;
- a correction of a line with pieces moves each piece's difference with it;
- a count: what moves between categories at the leaving one's average, what
  is found short at its average onto the shortage, found over at its
  category's average from the surplus;
- before that day the count writes no wage.

Run:
    python -m pytest tests/test_wage_moves_with_its_goods.py -v
"""
import uuid
from datetime import date

import pytest

from accounting.mappings import get_account_id_for_mapping
from models import Category, InvoiceItem, JournalEntryLine, Settings, WageAllocation, db
from services.pieces import PieceRefused, coding_view, open_coding, piece_wage, register_piece
from services.wage_ledger import pools, spread, unallocated_lines, wage_account_id
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_stock_coding import receiving  # noqa: F401
from tests.test_stock_count import NOW, _count, _safe, _stock, roles  # noqa: F401
from tests.test_supplier_purchase_effect import _vat, app, rollback_after_each, world  # noqa: F401
from tests.test_wage_allocation import _hand_entry


@pytest.fixture(autouse=True)
def pools_on(app):
    Settings.query.first().wage_pools_from = date(2026, 1, 1)
    db.session.flush()
    yield


def _category(tracking='weight'):
    c = Category(name=f'تصنيف وعاء {uuid.uuid4().hex[:6]}', karat='21', tracking=tracking)
    db.session.add(c)
    db.session.flush()
    return c


def _wages(category, riyals):
    spread(_hand_entry(riyals, day=NOW), [(21, category.id if category else None, None, 1.0)], now=NOW, what='وعاء')


def _pool(category):
    return pools().get((21, category.id if category else None), {'riyals': 0.0, 'grams': 0.0})


def _held(piece):
    return round(sum(a.riyals for a in WageAllocation.query.filter_by(item_id=piece.id)), 2)


# ── coding ───────────────────────────────────────────────────────────────────

def test_a_piece_coded_from_the_stock_takes_its_pools_average(app, roles):
    Settings.query.first().coding_from = date(2026, 1, 1)
    box, bangles = _safe(), _category('piece')
    _stock(box, 30.0, bangles)
    _wages(bangles, 600.0)                                              # 20 a gram
    batch = open_coding(safe_box_id=box.id, category_id=bangles.id, weight=30.0, by='t', now=NOW)
    with pytest.raises(PieceRefused) as typed:
        register_piece(batch, weight=10.0, wage=25, by='t', now=NOW)
    assert typed.value.code == 'piece_wage_from_pool', 'no wage written: its pool\'s'
    piece = register_piece(batch, weight=10.0, by='t', now=NOW)
    assert piece_wage(piece) == 200.0 and _held(piece) == 200.0, 'its own, out of its pool'
    assert _pool(bangles) == {'riyals': 400.0, 'grams': 20.0}, 'the rest at the same average'
    assert not unallocated_lines()


def test_the_station_shows_the_pools_wage_not_a_field(app, roles):
    Settings.query.first().coding_from = date(2026, 1, 1)
    box, bangles = _safe(), _category('piece')
    _stock(box, 30.0, bangles)
    _wages(bangles, 600.0)
    view = coding_view(open_coding(safe_box_id=box.id, category_id=bangles.id, weight=30.0, by='t', now=NOW))
    assert (view['wage_from_pool'], view['wage_by_piece'], view['pool_wage_per_gram']) == (True, False, 20.0)


# ── a receipt's pieces ───────────────────────────────────────────────────────

def _as_pieces(line):
    db.session.get(Category, line.category_id).tracking = 'piece'
    db.session.flush()


def test_a_receipts_piece_takes_its_share_of_its_invoices_wage(auth_headers, world, roles, showroom, receiving):
    from tests.test_receiving_correction_invoiced import _invoiced
    invoice, line = _invoiced(auth_headers, world)                      # 12.5 g x 18 = 225 in its category
    category = db.session.get(Category, line.category_id)
    _as_pieces(line)
    piece = register_piece(line, weight=5.0, by='t', now=NOW)
    assert _held(piece) == 90.0, '5 g x 18, its own'
    assert _pool(category)['riyals'] == 135.0, 'the rest its category\'s'


def test_a_piece_coded_before_its_invoice_takes_its_share_at_the_completion(auth_headers, world, roles, showroom,
                                                                              receiving):
    from tests.test_receiving_completes_one_document import _call, _id
    from tests.test_receiving_parts_are_the_whole import _screen
    status, body = _call(auth_headers, _screen(world), posting_part='gold')
    assert status == 201, body
    receipt = _id(body)
    line = InvoiceItem.query.filter_by(invoice_id=receipt).one()
    _as_pieces(line)
    piece = register_piece(line, weight=5.0, by='t', now=NOW)
    assert _held(piece) == 0.0, 'its wage not on 1320 yet'
    status, body = _call(auth_headers, _screen(world), posting_part='cash', complete_invoice_id=receipt)
    assert status in (200, 201), body
    assert _held(piece) == 90.0
    assert _pool(db.session.get(Category, line.category_id))['riyals'] == 135.0
    assert not unallocated_lines()


def test_a_correction_of_a_line_with_pieces_moves_each_pieces_difference(auth_headers, world, roles, showroom,
                                                                         receiving):
    from tests.test_receiving_correction_invoiced import _correct, _invoiced
    invoice, line = _invoiced(auth_headers, world)
    category = db.session.get(Category, line.category_id)
    _as_pieces(line)
    piece = register_piece(line, weight=5.0, by='t', now=NOW)
    _correct(invoice, line, showroom, wage_per_gram=20.0)              # 18 -> 20 a gram
    assert _held(piece) == 100.0, '5 g x 20'
    assert _pool(category)['riyals'] == 150.0, '7.5 g x 20'
    assert not unallocated_lines()


# ── the count ────────────────────────────────────────────────────────────────

def _cash(entry, role):
    account = get_account_id_for_mapping('افتراضي', role)
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0)
                     for l in JournalEntryLine.query.filter_by(journal_entry_id=entry.id, account_id=account)), 2)


def test_a_classification_moves_its_wages_at_the_unclassifieds_average(app, roles):
    from tests.test_classification_count import _open, _weigh
    from services.inventory_count_service import InventoryCountService as S
    box, bangles = _safe(), _category()
    _stock(box, 100.0)                                                  # «بلا تصنيف»
    _wages(None, 1000.0)                                                # 10 a gram
    session = _open(box)
    _weigh(session, box, bangles, 40.0)
    S.close_session(session, now=NOW)
    _, entry = S.approve_session(session, approved_by='المدير', now=NOW, adjustment_reason='classification')
    assert _pool(bangles) == {'riyals': 400.0, 'grams': 40.0}
    assert _pool(None) == {'riyals': 600.0, 'grams': 60.0}
    assert (_cash(entry, 'inventory_count_shortage'), _cash(entry, 'inventory_count_surplus')) == (0.0, 0.0)
    assert not unallocated_lines()


def test_a_shortage_loses_its_wage_at_its_average(app, roles):
    box, rings = _safe(), _category()
    _stock(box, 50.0, rings)
    _wages(rings, 500.0)                                                # 10 a gram
    _, entry = _count(box, {(rings.id, 21): 45.0}, roles)
    assert _cash(entry, 'inventory_count_shortage') == 50.0, '5 g x 10, a loss with its gold'
    assert _pool(rings) == {'riyals': 450.0, 'grams': 45.0}
    assert not unallocated_lines()


def test_a_surplus_enters_at_its_categorys_average(app, roles):
    box, chains = _safe(), _category()
    _stock(box, 20.0, chains)
    _wages(chains, 400.0)                                               # 20 a gram
    _, entry = _count(box, {(chains.id, 21): 25.0}, roles)
    assert _cash(entry, 'inventory_count_surplus') == -100.0, '5 g x 20, from the surplus'
    assert _pool(chains) == {'riyals': 500.0, 'grams': 25.0}
    assert not unallocated_lines()


def test_between_categories_at_the_leaving_ones_average(app, roles):
    """5 g short of the rings and 5 g over of the chains in one safe: moved, not lost nor gained."""
    box, rings, chains = _safe(), _category(), _category()
    _stock(box, 50.0, rings)
    _stock(box, 20.0, chains)
    _wages(rings, 500.0)                                                # 10 a gram
    _wages(chains, 400.0)                                               # 20 a gram
    _, entry = _count(box, {(rings.id, 21): 45.0, (chains.id, 21): 25.0}, roles)
    assert _pool(chains) == {'riyals': 450.0, 'grams': 25.0}, 'at the rings\' 10, not the chains\' 20'
    assert _pool(rings) == {'riyals': 450.0, 'grams': 45.0}
    assert (_cash(entry, 'inventory_count_shortage'), _cash(entry, 'inventory_count_surplus')) == (0.0, 0.0)


def test_before_its_day_a_count_writes_no_wage(app, roles):
    Settings.query.first().wage_pools_from = None
    db.session.flush()
    box, rings = _safe(), _category()
    _stock(box, 50.0, rings)
    _, entry = _count(box, {(rings.id, 21): 45.0}, roles)
    assert not JournalEntryLine.query.filter_by(journal_entry_id=entry.id, account_id=wage_account_id()).count()
