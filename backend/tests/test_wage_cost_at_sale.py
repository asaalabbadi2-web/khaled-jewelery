"""A sale's wage cost is the server's, from the pool or the piece (ADR-096 ت2; the owner, 19 Nov 2026).

On the 19 Nov copy the sales released 30.77 a gram from 1320 against 21.59
put in: the line's wage was the category's typed «متوسط أجور المصنعية». From
wage_pools_from on:
- a weighed line's cost is its pool's average at the sale times its grams --
  what the screen sent is not the cost; frozen on the line;
- a pool holding fewer grams than sold gives what it holds, no more; the
  night says so (WAGE_POOL_OVERSOLD);
- a piece's cost is its own wage;
- the invoice's cost -- its profit, its points -- follows by the difference;
- before that day the sale is as it was.

Run:
    python -m pytest tests/test_wage_cost_at_sale.py -v
"""
from datetime import date

import pytest

from models import Invoice, InvoiceItem, Settings, db
from services.wage_ledger import spread
from tests.retraction_world import _payload, world  # noqa: F401
from tests.test_wage_allocation import NOW, _allocations, _category, _hand_entry
from tests.test_wage_treatment_follows_the_setting import (  # noqa: F401
    _create, _moved, _settings, app, books, rollback_after_each, _vat)


def _pool(category, grams, riyals):
    """A category's pool: its grams in a stock safe, its riyals on 1320."""
    from tests.test_stock_count import _safe, _stock
    _stock(_safe('showroom'), grams, category)
    spread(_hand_entry(riyals, day=NOW), [(21, category.id, None, 1.0)], now=NOW, what='وعاء')


def _sale(world, category, grams, typed_wage):
    payload = _payload(world, 'sale_on_credit', held=False)
    payload['items'][0].update(weight=grams, wage=typed_wage, category_id=category.id)
    payload['total_weight'] = grams
    payload['total_cost'] = 700.0 + typed_wage * grams              # the screen's: gold + its wage
    return payload


def _on():
    Settings.query.first().wage_pools_from = date(2026, 1, 1)
    db.session.flush()


def test_a_weighed_line_costs_its_pools_average(auth_headers, books, world):
    _settings('inventory')
    _on()
    bangles = _category()
    _pool(bangles, 40.0, 800.0)                                      # 20 a gram
    inv = _create(auth_headers, _sale(world, bangles, 2.0, typed_wage=42.0))
    assert _moved(inv['id'], books['wage_inventory']) == (0.0, 40.0), '2 g x 20, not x 42'
    line = InvoiceItem.query.filter_by(invoice_id=inv['id']).one()
    assert line.wage == pytest.approx(20.0), 'the cost frozen on the line'
    assert db.session.get(Invoice, inv['id']).total_cost == pytest.approx(700.0 + 40.0), 'its profit follows'
    assert _allocations(inv['id']) == {(bangles.id, None): -40.0}


def test_a_pool_short_of_grams_gives_what_it_holds(auth_headers, books, world):
    from services.books_invariants import WAGE_POOL_OVERSOLD, check_wage_pools_oversold
    _settings('inventory')
    _on()
    rings = _category()
    _pool(rings, 1.0, 30.0)
    inv = _create(auth_headers, _sale(world, rings, 2.0, typed_wage=42.0))
    assert _moved(inv['id'], books['wage_inventory']) == (0.0, 30.0), 'what it holds, never below zero'
    from tests.test_stock_count import _safe
    from models import JournalEntry, JournalEntryLine
    from services.stock_ledger import allocate
    box = _safe('showroom')
    je = JournalEntry(entry_number='JE-W-OUT', date=NOW, description='بيع', entry_type='عادي', is_posted=True,
                      is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    out = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, credit_21k=2.0)
    db.session.add(out)
    db.session.flush()
    allocate(out, 21, rings.id, -2.0, now=NOW)                       # its 2 g out of 1 g held
    [fact] = [f for f in check_wage_pools_oversold() if f.detail['category_id'] == rings.id]
    assert (fact.kind, fact.metric) == (WAGE_POOL_OVERSOLD, -1.0)


def test_a_piece_costs_its_own_wage(app, books):
    """The piece's line its own -- coded from its pool, the pool's average then (ت3); a weighed
    line of its category the pool's, what is left in it."""
    from services.pieces import register_piece
    from services.wage_ledger import sale_wage_costs
    from tests.test_piece_wage_written_at_coding import _batch
    from tests.test_stock_coding import _stock
    from tests.test_stock_count import _safe
    from models import Category
    _settings('inventory')
    _on()
    Settings.query.first().coding_from = date(2026, 1, 1)
    bangles = Category(name='بنجرة تكلفة', karat='21', tracking='piece')
    db.session.add(bangles)
    db.session.flush()
    showroom = _safe('showroom')
    _stock(showroom, bangles, 30.0)
    spread(_hand_entry(600.0, day=NOW), [(21, bangles.id, None, 1.0)], now=NOW, what='وعاء')
    piece = register_piece(_batch(showroom, bangles, 10.0), weight=10.0, by='t', now=NOW)            # 600 / 30 g x 10
    sale = Invoice(invoice_type='بيع', invoice_type_id=1, date=NOW, total=0.0)
    db.session.add(sale)
    db.session.flush()
    a = InvoiceItem(invoice_id=sale.id, item_id=piece.id, karat=21, weight=10.0, wage=99.0, quantity=1, price=0.0)
    b = InvoiceItem(invoice_id=sale.id, category_id=bangles.id, karat=21, weight=4.0, wage=99.0, quantity=1,
                    price=0.0)
    db.session.add_all([a, b])
    db.session.flush()
    assert sale_wage_costs(sale) == {a.id: 200.0, b.id: 80.0}, 'its own 200; the 400 left over its 20 g, 4 g'


def test_before_its_day_the_sale_is_as_it_was(auth_headers, books, world):
    _settings('inventory')
    bangles = _category()
    inv = _create(auth_headers, _sale(world, bangles, 2.0, typed_wage=42.0))
    assert _moved(inv['id'], books['wage_inventory']) == (0.0, 84.0), "2026's books: the typed wage"


def test_the_screen_reads_the_pools_cost_and_whether_it_is_on(auth_headers, books):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    _settings('inventory')
    bangles = _category()
    _pool(bangles, 40.0, 800.0)
    g.pop('current_user', None)
    off = flask_app.test_client().get('/api/settings', headers=auth_headers).get_json()
    assert (off['wage_pools_from'], off['wage_pools_active']) == (None, False)
    _on()
    g.pop('current_user', None)
    on = flask_app.test_client().get('/api/settings', headers=auth_headers).get_json()
    assert (on['wage_pools_from'], on['wage_pools_active']) == ('2026-01-01', True)
    g.pop('current_user', None)
    r = flask_app.test_client().get(f'/api/wage-pools/cost?karat=21&category_id={bangles.id}', headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    assert (r.get_json()['per_gram'], r.get_json()['grams'], r.get_json()['active']) == (20.0, 40.0, True)
