"""A sale's «تصحيح فاتورة» moves its wage between pools (ADR-096 ت1).

The sale as posted gives its line's wage back to its category; the right
lines take theirs out: one net line on 1320, allocated whole, each part in
its own sign.

Run:
    python -m pytest tests/test_wage_allocation_sale_correction.py -v
"""
from datetime import date

import pytest

from models import Settings, WageAllocation, db
from services.wage_ledger import unallocated_lines, wage_account_id
from tests.test_gold_sold_at_its_cost import _square, world  # noqa: F401 (fixture)
from tests.test_invoice_correction_sale import _behind_the_fence, _correct, _entry, _sold  # noqa: F401


def test_a_weight_put_right_moves_its_wage_between_the_lines(auth_headers, world):
    from models import Category
    Settings.query.first().wage_pools_from = date(2026, 1, 1)
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    invoice, line = _sold(auth_headers, world)                    # 10 g of 21k, no wage at sale
    chains = Category(name='سلاسل أجور', karat='21', is_active=True, is_scrap=False)
    db.session.add(chains)
    db.session.flush()
    line.wage, invoice.manufacturing_wage_mode_snapshot = 20.0, 'inventory'
    db.session.flush()
    sold_as = line.category_id                                    # the line is rewritten in its place
    correction, lines = _entry(_correct(auth_headers, invoice, line, [
        {'karat': 21, 'weight': 11.0, 'price': 7000.0, 'category_id': chains.id}]))
    [wage_line] = [l for l in lines if l.account_id == wage_account_id()]
    rows = {a.category_id: a.riyals for a in WageAllocation.query.filter_by(journal_entry_line_id=wage_line.id)}
    assert rows == {sold_as: 200.0, chains.id: -220.0}, 'the old line\'s back, the right one\'s out'
    assert round(sum(rows.values()), 2) == -20.0, '1 g more at 20 a gram, out of the pools'
    assert not unallocated_lines()
