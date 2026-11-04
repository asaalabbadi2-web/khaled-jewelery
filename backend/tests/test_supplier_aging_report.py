"""The suppliers' aging, from the running account's reading (REPORTS ت3-2ب, ADR-083).

What the shop owes each supplier on a day, by how old each open item is --
0-30, 31-60, 61-90, over 90 days, the customers' aging's buckets -- in
riyals or in grams, what is paid ahead apart; each supplier's total its
ledger balance on that day (the reading's law, said as a check). A day
counts whole; what comes after it is not read.

Run:
    python -m pytest tests/test_supplier_aging_report.py -v
"""
import datetime as dt

import pytest

from tests.test_supplier_running_account import _invoice, _post, _supplier, _voucher

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _aging(as_of, dimension='gold'):
    from services.reports.supplier_aging import supplier_aging
    return supplier_aging(as_of=as_of, dimension=dimension, now=D(2043, 9, 1, 10))


def _row(report, supplier):
    return next(r for r in report.rows if r.get('drill') == {'kind': 'supplier', 'id': supplier.id})


@pytest.fixture
def books():
    from pricing.karat_service import convert_to_main_karat
    supplier, weight = _supplier()
    a, b = _invoice(supplier, 1), _invoice(supplier, 20)
    _post(supplier, weight, 1, 10.0, 'invoice', a.id)          # 1 May
    _post(supplier, weight, 20, 5.0, 'invoice', b.id)          # 20 May
    v = _voucher(25)
    _post(supplier, weight, 25, -4.0, 'voucher', v.id)         # the oldest: A 6 left
    return {'supplier': supplier, 'g': lambda x: convert_to_main_karat(x, 21)}


def test_each_open_item_in_its_age_s_bucket(books):
    g = books['g']
    row = _row(_aging(dt.date(2043, 6, 15)), books['supplier'])
    assert row['days_31_60'] == pytest.approx(g(6.0), abs=1e-6), 'A: 45 days'
    assert row['days_0_30'] == pytest.approx(g(5.0), abs=1e-6), 'B: 26 days'
    assert row['total'] == pytest.approx(g(11.0), abs=1e-6)


def test_a_day_counts_whole_what_comes_after_is_not_read(books):
    g = books['g']
    report = _aging(dt.date(2043, 5, 10))
    row = _row(report, books['supplier'])
    assert row['days_0_30'] == pytest.approx(g(10.0), abs=1e-6)
    assert row['total'] == pytest.approx(g(10.0), abs=1e-6)
    assert report.end == dt.date(2043, 5, 10)


def test_paid_ahead_is_apart_and_the_total_is_the_ledger_s(books):
    g = books['g']
    from models import Account, db
    supplier = books['supplier']
    weight = db.session.get(Account, supplier.account.memo_account_id)
    v = _voucher(26)
    _post(supplier, weight, 26, -20.0, 'voucher', v.id)        # 11 open: 9 ahead
    report = _aging(dt.date(2043, 6, 15))
    row = _row(report, supplier)
    assert row['prepaid'] == pytest.approx(-g(9.0), abs=1e-6)
    assert row['total'] == pytest.approx(-g(9.0), abs=1e-6)
    assert {c.key: c.ok for c in report.checks}['agrees_with_ledger']


def test_riyals_on_their_own():
    supplier, _ = _supplier()
    from dual_system_helpers import create_dual_journal_entry
    from models import JournalEntry, db
    a = _invoice(supplier, 1)
    entry = JournalEntry(date=D(2043, 5, 1, 12), description='جاري', entry_type='عادي', is_posted=True,
                         created_by='t', reference_type='invoice', reference_id=a.id)
    db.session.add(entry)
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=supplier.account_id, supplier_id=supplier.id,
                              apply_golden_rule=False, cash_credit=1500.0)
    db.session.flush()
    report = _aging(dt.date(2043, 8, 15), 'cash')
    row = _row(report, supplier)
    assert row['over_90'] == pytest.approx(1500.0)
    assert {c.key: c.kind for c in report.columns}['total'] == 'money'
