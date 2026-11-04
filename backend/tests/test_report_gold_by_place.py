"""The shop's gold by its place on a day, from the balance sheet's own weight side (REPORTS ت5-2, ADR-083).

The owner, 4 Nov 2026 («الذهب حسب مكانه»): «مركز الذهب» summed every
account's weight, assets and liabilities alike, and showed a «short position»
of -5,147 g where the balance sheet's assets held 42,509 g, balanced. This
reads the assets' grams as the balance sheet reads them -- each group's money
accounts and their weight twins -- and lists each place that holds gold: its
grams of each karat as they are, and in the main karat. Its total is the
balance sheet's assets in grams (the check reads the sheet itself), and a
note values it at today's price, saying the price.

Run:
    python -m pytest tests/test_report_gold_by_place.py -v
"""
import datetime as dt

import pytest

from models import SafeBox, db
from tests.test_report_balance_sheet import D, _child, _entry


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _places(day):
    from services.reports.gold_by_place import gold_by_place
    return gold_by_place(as_of=day, now=D(2041, 12, 31))


@pytest.fixture
def held():
    from accounting.chart_tree import LIABILITIES_ROOT
    display, group = _child('assets_root', 'المعروض')
    custody, _ = _child('assets_root', 'عهدة موظف')
    supplier, _ = _child(LIABILITIES_ROOT, 'مورد ذهب')
    db.session.add(SafeBox(name='خزينة المعروض', safe_type='gold', account_id=display.memo_account_id, is_active=True))
    db.session.flush()
    _entry(D(2041, 9, 4), [(display.memo_account_id, {'debit_21k': 10.0, 'debit_18k': 7.0}),
                           (supplier.memo_account_id, {'credit_21k': 10.0, 'credit_18k': 7.0})])
    _entry(D(2041, 9, 6), [(custody.memo_account_id, {'debit_24k': 3.5}),
                           (supplier.memo_account_id, {'credit_24k': 3.5})])
    return {'display': display, 'custody': custody, 'group': group}


def _row(report, account_id):
    return next(r for r in report.rows if r.get('account_id') == account_id)


def test_each_place_its_karats_as_they_are_and_in_the_main_karat(held):
    report = _places(dt.date(2041, 9, 30))
    display = _row(report, held['display'].memo_account_id)
    assert display['k21'] == pytest.approx(10.0) and display['k18'] == pytest.approx(7.0)
    assert display['main'] == pytest.approx(10.0 + 7.0 * 18 / 21)
    assert display['name'] == 'خزينة المعروض', 'a safe says its own name'
    assert display['drill'] == {'kind': 'account', 'id': held['display'].memo_account_id}
    custody = _row(report, held['custody'].memo_account_id)
    assert custody['k24'] == pytest.approx(3.5) and custody['main'] == pytest.approx(4.0)


def test_a_day_before_does_not_see_it(held):
    report = _places(dt.date(2041, 9, 5))
    assert _row(report, held['display'].memo_account_id)['k21'] == pytest.approx(10.0)
    assert all(r.get('account_id') != held['custody'].memo_account_id for r in report.rows)


def test_its_total_is_the_balance_sheet_s_assets_in_grams(held):
    from services.reports.balance_sheet import balance_sheet
    day = dt.date(2041, 9, 30)
    report = _places(day)
    sheet = balance_sheet(as_of=day, now=D(2041, 12, 31))
    assets = next(r for r in sheet.rows if r.get('key') == 'assets_total')['weight']
    assert report.totals['main'] == pytest.approx(assets, abs=0.001)
    assert {c.key: c.ok for c in report.checks} == {'the_balance_sheet_s': True}


def test_the_customers_group_says_what_its_grams_are(held):
    """CUSTGOLD-001: a group holding customers' accounts says its grams are the
    weight twins' dual-system weights, not gold at the customers."""
    import uuid

    from models import Customer
    account, _ = _child('assets_root', 'حساب عميل')
    db.session.add(Customer(customer_code=f'C-{uuid.uuid4().hex[:6]}', name='عميل', account_id=account.id))
    db.session.flush()
    _entry(D(2041, 9, 7), [(account.memo_account_id, {'debit_21k': 5.0}),
                           (held['display'].memo_account_id, {'credit_21k': 5.0})])
    notes = [r['name'] for r in _places(dt.date(2041, 9, 30)).rows if r.get('style') == 'note']
    assert any('CUSTGOLD-001' in n for n in notes)
