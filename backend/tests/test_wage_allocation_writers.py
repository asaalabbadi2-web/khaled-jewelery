"""Every writer on the wages' stock (1320) allocates its lines (ADR-096 ت1).

With wage_pools_from on, the guard refuses a commit leaving a line on 1320
not allocated -- so a writer that forgets refuses its own document. Here each
writer the 19 Nov copy shows on 1320, beside the invoice's posting
(tests/test_wage_allocation.py): a receipt completed by its invoice, its
correction («تصحيح فاتورة»), its cancellation, a reversal.

Run:
    python -m pytest tests/test_wage_allocation_writers.py -v
"""
from datetime import date

import pytest

from models import JournalEntryLine, Settings, WageAllocation, db
from services.wage_ledger import unallocated_lines, wage_account_id
from tests.test_receiving_cancelled import _cancel
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_receiving_correction_invoiced import _correct, _invoiced
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


@pytest.fixture(autouse=True)
def pools_on(app):
    Settings.query.first().wage_pools_from = date(2026, 1, 1)
    db.session.flush()
    yield


def _pools_of(entry_id):
    """{category_id: riyals} the entry's lines on 1320 put in (+) or took out (-)."""
    out = {}
    for line in JournalEntryLine.query.filter_by(journal_entry_id=entry_id, account_id=wage_account_id()):
        for a in WageAllocation.query.filter_by(journal_entry_line_id=line.id):
            out[a.category_id] = round(out.get(a.category_id, 0.0) + a.riyals, 2)
    return out


def test_a_receipt_completed_by_its_invoice_puts_its_wages_in_its_category(auth_headers, world, roles, showroom):
    invoice, item = _invoiced(auth_headers, world)
    db.session.commit()
    assert not unallocated_lines(), 'its lines on 1320 allocated whole'
    from tests.test_wage_allocation import _allocations
    assert _allocations(invoice.id) == {(item.category_id, None): 225.0}, '12.5 g x 18'


def test_a_wage_corrected_moves_its_difference_in_its_category(auth_headers, world, roles, showroom):
    invoice, item = _invoiced(auth_headers, world)
    entry = _correct(invoice, item, showroom, wage_per_gram=20.0).journal_entry_id
    db.session.commit()
    assert _pools_of(entry) == {item.category_id: 25.0}, '12.5 g x (20 - 18)'
    assert not unallocated_lines()


def test_a_receipt_cancelled_takes_its_wages_out(auth_headers, world, roles, showroom):
    invoice, item = _invoiced(auth_headers, world)
    entry = _cancel(invoice, showroom).journal_entry_id
    db.session.commit()
    assert _pools_of(entry) == {item.category_id: -225.0}
    assert not unallocated_lines()


def test_a_reversal_takes_back_its_lines_pools(app, roles):
    """The voucher's reversal (routes/vouchers) mirrors each line's pools, as its gold's categories."""
    from tests.test_wage_allocation import NOW as LATER, _category, _hand_entry
    from services.wage_ledger import mirror_wage_allocations, spread
    from tests.test_wage_treatment_follows_the_setting import _settings
    _settings('inventory')
    bangles, rings = _category(), _category()
    original = _hand_entry(-90.0, day=LATER)
    spread(original, [(21, bangles.id, None, 2.0), (21, rings.id, None, 1.0)], now=LATER, what='صهر')
    reversal = _hand_entry(90.0, day=LATER)
    mirror_wage_allocations([(original, reversal)], now=LATER)
    db.session.commit()
    assert {a.category_id: a.riyals for a in WageAllocation.query.filter_by(journal_entry_line_id=reversal.id)} \
        == {bangles.id: 60.0, rings.id: 30.0}


def test_a_line_netting_its_parts_is_laid_in_proportion(app, roles):
    """A correction's VAT on 1320 (the wages' VAT not recovered) nets its parts at the VAT's rate."""
    from tests.test_wage_allocation import NOW as LATER, _category, _hand_entry
    from services.wage_ledger import spread_net
    from tests.test_wage_treatment_follows_the_setting import _settings
    _settings('inventory')
    old, right = _category(), _category()
    parts = [(21, old.id, None, -100.0), (21, right.id, None, 150.0)]         # the wage's difference: +50
    wage, vat = _hand_entry(50.0, day=LATER), _hand_entry(7.5, day=LATER)
    spread_net(wage, parts, now=LATER, what='تصحيح')
    spread_net(vat, parts, now=LATER, what='تصحيح')
    db.session.commit()
    rows = lambda line: {a.category_id: a.riyals for a in WageAllocation.query.filter_by(journal_entry_line_id=line.id)}
    assert rows(wage) == {old.id: -100.0, right.id: 150.0}
    assert rows(vat) == {old.id: -15.0, right.id: 22.5}


def test_a_melting_writes_its_pools_wage_off_at_their_average(auth_headers, roles, monkeypatch):
    """From 2027's opening a melting's wage is its pools' own at their average -- the
    server's, not the one written (ADR-096 ت3): 2.5 g of 21k at 20, 1.5 g of 18k at 15."""
    from models import AccountingMapping, Voucher
    from routes import system as system_routes
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    from services.wage_ledger import spread
    from tests.test_melting_is_one_voucher import _account, _gold_safe, _ledger, _post, _vouchers_from
    from tests.test_wage_allocation import NOW as LATER, _hand_entry
    monkeypatch.setattr(system_routes, 'wages_are_capitalized', lambda mode: True)
    monkeypatch.setattr(system_routes, '_get_manufacturing_wage_inventory_account_id', wage_account_id)
    damaged = _account('5', 'مصروف مصنعية تالفة', type='Expense')
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                     account_type='melting_damaged_wage', account_id=damaged.id, is_active=True))
    db.session.flush()
    source, target = _gold_safe('معروض'), _gold_safe('كسر', 'scrap')
    from services.stock_ledger import allocate as stock_allocate
    from tests.test_wage_allocation import _category
    rings, chains = _category('21'), _category('18')
    for karat, category, riyals in ((21, rings, 200.0), (18, chains, 150.0)):    # 10 g each: 20 and 15 a gram
        _ledger(source, karat, 10.0)
        line = (JournalEntryLine.query.filter_by(account_id=source.account_id)
                .order_by(JournalEntryLine.id.desc()).first())
        stock_allocate(line, karat, category.id, 10.0, now=LATER, by='t')
        spread(_hand_entry(riyals, day=LATER), [(karat, category.id, None, 1.0)], now=LATER, what='وعاء')
    resp = _post(auth_headers, {
        'operation_type': 'melting', 'from_safe_box_id': source.id, 'to_safe_box_id': target.id,
        'lines': [{'karat': 21, 'gold_weight': 2.0, 'category_id': rings.id},
                  {'karat': 18, 'gold_weight': 1.5, 'category_id': chains.id},
                  {'karat': 21, 'gold_weight': 0.5, 'category_id': rings.id}],
        'damage_wage_amount': 100.0, 'damage_wage_account_id': damaged.id,
    })
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    [voucher] = _vouchers_from(source)
    entry = db.session.get(Voucher, voucher.id).journal_entry_id
    by_karat = {}
    for line in JournalEntryLine.query.filter_by(journal_entry_id=entry, account_id=wage_account_id()):
        for a in WageAllocation.query.filter_by(journal_entry_line_id=line.id):
            by_karat[a.karat] = round(by_karat.get(a.karat, 0.0) + a.riyals, 2)
    assert by_karat == {21: -50.0, 18: -22.5}, 'each pool at its average, not the 100 written'
    damaged_line = JournalEntryLine.query.filter_by(journal_entry_id=entry, account_id=damaged.id).one()
    assert round(float(damaged_line.cash_debit or 0), 2) == 72.5
    assert not unallocated_lines()
