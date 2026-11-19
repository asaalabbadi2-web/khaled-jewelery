"""The wages' stock by category and piece (ADR-096 ت1; the owner, 19 Nov 2026).

On the 19 Nov copy the sales released 30.77 a gram from 1320 against the
21.59 the purchases put in: 1320 knew its riyals and not whose. From
Settings.wage_pools_from on (2027's opening):
- a posting lays its lines on 1320 on its items -- each its wage per gram x
  its weight, the halala's rounding on the last: the line allocated whole,
  to its category's pool, or to a piece's own wage;
- a line on 1320 left not allocated refuses its commit: no hand's entry;
- a pool reads its riyals here and its grams in the stock;
- before that day nothing is allocated or refused: 2026's books as they are.

Run:
    python -m pytest tests/test_wage_allocation.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from models import Category, JournalEntry, JournalEntryLine, Settings, WageAllocation, db
from services.wage_ledger import (WageAllocationError, allocate, pools, spread, unallocated_lines,
                                  wage_account_id)
from tests.purchase_category import categorized
from tests.test_wage_treatment_follows_the_setting import (  # noqa: F401
    _create, _settings, app, books, rollback_after_each, _vat)
from tests.retraction_world import world  # noqa: F401

NOW = datetime(2027, 1, 5, 10, 0)


@pytest.fixture
def pools_on(app):
    Settings.query.first().wage_pools_from = date(2026, 1, 1)
    db.session.flush()
    yield


def _category(karat='21'):
    c = Category(name=f'تصنيف أجور {uuid.uuid4().hex[:6]}', karat=karat, is_active=True, is_scrap=False)
    db.session.add(c)
    db.session.flush()
    return c


def _purchase(b, lines):
    """Lines (category, grams, wage per gram) of 21k, on credit, VAT 15 % on the wages."""
    wage = round(sum(g * w for _, g, w in lines), 2)
    vat = round(wage * 0.15, 2)
    return {
        'invoice_type': 'شراء', 'supplier_id': b['supplier'].id, 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'total': wage + vat, 'total_tax': vat,
        'gold_subtotal': 0.0, 'wage_subtotal': wage, 'wage_tax_total': vat, 'gold_tax_total': 0.0,
        'settlement_method': 'credit', 'amount_paid': 0.0,
        'items': [{'name': c.name, 'karat': 21, 'weight': g, 'quantity': 1, 'category_id': c.id,
                   'manufacturing_wage_per_gram': w} for c, g, w in lines],
    }


def _allocations(invoice_id):
    rows = (WageAllocation.query.join(JournalEntryLine, JournalEntryLine.id == WageAllocation.journal_entry_line_id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id).all())
    return {(r.category_id, r.item_id): round(r.riyals, 2) for r in rows}


def _hand_entry(riyals, day=NOW):
    je = JournalEntry(entry_number=f'JE-W-{uuid.uuid4().hex[:8]}', date=day, description='تصحيح يدوي',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=wage_account_id(), cash_debit=riyals)
    db.session.add(line)
    db.session.flush()
    return line


def test_a_purchase_lays_its_wages_on_its_categories(auth_headers, books, pools_on):
    _settings('inventory')
    bangles, rings = _category(), _category()
    inv = _create(auth_headers, _purchase(books, [(bangles, 10.0, 20.0), (rings, 3.0, 33.33)]))
    assert _allocations(inv['id']) == {(bangles.id, None): 200.0, (rings.id, None): 99.99}
    assert not unallocated_lines(), 'each line on 1320 allocated whole'


def test_a_sale_takes_its_wage_from_its_category(auth_headers, books, world, pools_on):
    from tests.retraction_world import _payload
    _settings('inventory')
    from tests.test_stock_count import _safe, _stock
    payload = _payload(world, 'sale_on_credit', held=False)
    payload['items'][0]['wage'] = 99.0                  # the screen's: not the cost (ت2)
    categorized(payload['items'])
    category = db.session.get(Category, payload['items'][0]['category_id'])
    _stock(_safe('showroom'), 40.0, category)
    spread(_hand_entry(400.0), [(21, category.id, None, 1.0)], now=NOW, what='وعاء')   # 10 a gram
    inv = _create(auth_headers, payload)
    assert _allocations(inv['id']) == {(category.id, None): -20.0}, '2 g at its pool\'s 10'


def test_before_its_day_nothing_is_allocated_nor_refused(auth_headers, books):
    _settings('inventory')
    bangles = _category()
    inv = _create(auth_headers, _purchase(books, [(bangles, 10.0, 20.0)]))
    assert _allocations(inv['id']) == {}
    _hand_entry(50.0)
    db.session.commit()                         # 2026's books: a hand's entry as before


def test_a_hand_entry_on_the_wages_stock_is_refused(app, books, pools_on):
    _settings('inventory')
    _hand_entry(63676.73)
    with pytest.raises(WageAllocationError) as refused:
        db.session.commit()
    assert 'لا قيد يدوي' in refused.value.message


def test_a_line_allocated_whole_is_written(app, books, pools_on):
    _settings('inventory')
    bangles = _category()
    line = _hand_entry(100.0)
    spread(line, [(21, bangles.id, None, 3.0), (21, None, None, 1.0)], now=NOW, what='تجربة')
    db.session.commit()
    assert sorted(round(r.riyals, 2) for r in WageAllocation.query.filter_by(journal_entry_line_id=line.id)) \
        == [25.0, 75.0]


def test_the_allocation_laws(app, books, pools_on):
    _settings('inventory')
    bangles = _category()
    line = _hand_entry(100.0)
    with pytest.raises(WageAllocationError):
        allocate(line, karat=21, category_id=bangles.id, riyals=-10.0, now=NOW)      # against its sign
    allocate(line, karat=21, category_id=bangles.id, riyals=60.0, now=NOW)
    with pytest.raises(WageAllocationError):
        allocate(line, karat=21, category_id=bangles.id, riyals=40.01, now=NOW)      # more than the line
    with pytest.raises(WageAllocationError):
        spread(_hand_entry(5.0), [], now=NOW, what='بلا أصناف')                     # no item to lay it on


def test_a_pool_is_its_riyals_here_and_its_grams_in_the_stock(app, books, pools_on):
    from tests.test_stock_count import _safe, _stock
    _settings('inventory')
    bangles = _category()
    showroom, deposit = _safe('showroom'), _safe('deposit')
    _stock(showroom, 40.0, bangles)
    _stock(deposit, 7.0, bangles)                 # an office's deposit is not ours to sell
    spread(_hand_entry(800.0), [(21, bangles.id, None, 1.0)], now=NOW, what='تجربة')
    assert pools()[(21, bangles.id)] == {'riyals': 800.0, 'grams': 40.0}, '20 a gram'


def test_the_halalas_rounding_goes_to_the_last(app, books, pools_on):
    _settings('inventory')
    a, b, c = _category(), _category(), _category()
    line = _hand_entry(100.0)
    spread(line, [(21, a.id, None, 1.0), (21, b.id, None, 1.0), (21, c.id, None, 1.0)], now=NOW, what='تجربة')
    db.session.commit()
    got = {r.category_id: round(r.riyals, 2) for r in WageAllocation.query.filter_by(journal_entry_line_id=line.id)}
    assert got == {a.id: 33.33, b.id: 33.33, c.id: 33.34}


def test_a_sold_piece_takes_its_own_wage_not_its_categorys(app, books, pools_on):
    """A piece's wage is its own (ADR-096 §1): its share of the sale's line names it."""
    from models import Invoice, InvoiceItem
    from services.wage_ledger import invoice_wage_parts
    from tests.test_piece_wage_written_at_coding import _batch
    from tests.test_stock_coding import _stock
    from tests.test_stock_count import _safe
    from services.pieces import register_piece
    Settings.query.first().coding_from = date(2026, 1, 1)
    bangles = Category(name=f'بنجرة أجور {uuid.uuid4().hex[:6]}', karat='21', tracking='piece')
    db.session.add(bangles)
    db.session.flush()
    showroom = _safe('showroom')
    _stock(showroom, bangles, 20.0)
    piece = register_piece(_batch(showroom, bangles, 20.0), weight=10.0, wage=300, wage_whole=True, by='t', now=NOW)
    sale = Invoice(invoice_type='بيع', invoice_type_id=1, date=NOW, total=0.0)
    db.session.add(sale)
    db.session.flush()
    db.session.add_all([
        InvoiceItem(invoice_id=sale.id, item_id=piece.id, karat=21, weight=10.0, wage=30.0, quantity=1, price=0.0),
        InvoiceItem(invoice_id=sale.id, category_id=bangles.id, karat=21, weight=2.0, wage=15.0, quantity=1,
                    price=0.0)])
    db.session.flush()
    assert invoice_wage_parts(sale) == [(21, bangles.id, piece.id, 300.0), (21, bangles.id, None, 30.0)]


# ── the nightly check ───────────────────────────────────────────────────────

def test_the_night_sees_a_line_not_allocated_and_a_pool_below_zero(app, books, pools_on):
    from services.books_invariants import (WAGE_POOL_NEGATIVE, WAGES_NOT_ALLOCATED, check_wage_pools_negative,
                                           check_wages_not_allocated)
    from services.finding_kinds import KIND_INFO, subject_label
    _settings('inventory')
    bangles = _category()
    left = _hand_entry(40.0)                                 # got past the guard: no commit here
    sold = _hand_entry(-90.0)
    spread(sold, [(21, bangles.id, None, 1.0)], now=NOW, what='تجربة')
    [fact] = check_wages_not_allocated()
    assert (fact.kind, fact.subject_key, fact.metric) == (WAGES_NOT_ALLOCATED, f'journal_entry_line:{left.id}', 40.0)
    [pool] = check_wage_pools_negative()
    assert (pool.kind, pool.metric) == (WAGE_POOL_NEGATIVE, -90.0)
    assert subject_label(pool.subject_key) == f'أجور عيار 21 — تصنيف رقم {bangles.id}'
    assert {WAGES_NOT_ALLOCATED, WAGE_POOL_NEGATIVE} <= set(KIND_INFO)


def test_the_night_sees_nothing_before_its_day(app, books):
    from services.books_invariants import check_wage_pools_negative, check_wages_not_allocated
    _settings('inventory')
    _hand_entry(40.0)
    assert check_wages_not_allocated() == [] and check_wage_pools_negative() == []
