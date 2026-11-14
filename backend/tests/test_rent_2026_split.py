"""The rent of 2026 in two, the months restated in their months (ADR-090, 14 Nov 2026).

The owner: the first half paid with its VAT, claimed in the third quarter's
return; the second half net, its VAT on the December voucher -- «اريد ان
تتطابق ضريبة مدخلاتي مع كشف المحاسب». And option B: July to October restated
in their months, not gathered into November. Synthetic books, as the 2026
tool leaves them.

Run:
    python -m pytest tests/test_rent_2026_split.py -v
"""
import json
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from models import JournalEntry, PeriodExpense, PeriodExpenseRevision, db
from services.period_expense import _ledger_balance, accrue, riyals, values
from services.repair.planned_entries import PlanRefused
from services.repair.rent_2026_split import FIGURES, apply
from tests.period_expense_world import books, debits, expense, pay  # noqa: F401 (fixture)
from tests.voucher_world import auto_post, vworld  # noqa: F401 (fixture)

NOW = datetime(2026, 11, 14, 12, 0)
OCTOBER = date(2026, 10, 31)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


@pytest.fixture
def as_the_2026_tool_left_it(auth_headers, books):
    auto_post(True)
    rent = expense(books)                                         # «إيجار المعرض 2026», 144,900, the year
    assert pay(auth_headers, books, rent, 72450, date(2026, 6, 24)).status_code == 201
    accrue(OCTOBER, by='t', now=NOW, dry_run=False)               # January-October at 12,075
    return {**books, 'rent': rent}


def _month_expense(account_id, month):
    from accounting.balances import counted_line_filters
    from models import JournalEntryLine
    total = (db.session.query(db.func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters(), JournalEntryLine.account_id == account_id,
                     db.func.to_char(JournalEntry.date, 'YYYY-MM') == month).scalar())
    return round(float(total or 0), 2)


def _run(dry_run=False, figures=None):
    return apply(through=OCTOBER, by='rent_2026_split', now=NOW, dry_run=dry_run, figures=figures)


def test_each_month_its_rent_the_first_half_as_paid_the_second_net(as_the_2026_tool_left_it):
    b = as_the_2026_tool_left_it
    plan = _run()
    assert plan['applied'] and plan['reclass'] == [] and plan['drift'] == []
    assert [(r['month'], r['amount']) for r in plan['restated']] == [
        ('2026-07', -12075.0), ('2026-08', -12075.0), ('2026-09', -12075.0), ('2026-10', -12075.0)]
    assert [(e['month'], e['amount']) for e in plan['second_half_months']] == [
        ('2026-07', 10500.0), ('2026-08', 10500.0), ('2026-09', 10500.0), ('2026-10', 10500.0)]
    assert [_month_expense(b['rent_account'], f'2026-{m:02d}') for m in range(1, 11)] == [12075.0] * 6 + [10500.0] * 4
    # owed at the end of October: the second half's four months
    assert riyals(_ledger_balance(b['accrued'], OCTOBER)) == -42000.0
    rent = db.session.get(PeriodExpense, b['rent'].id)
    assert (float(rent.amount), rent.period_end) == (72450.0, date(2026, 6, 30))
    assert values(rent, OCTOBER)['standing'] == 'settled'
    assert PeriodExpenseRevision.query.filter_by(period_expense_id=rent.id).count() == 1
    # the months already posted are untouched: each restatement an entry of its own
    assert JournalEntry.query.filter(JournalEntry.reference_number.like('%/restated')).count() == 4


def test_november_and_december_then_accrue_only_the_second_half(as_the_2026_tool_left_it):
    b = as_the_2026_tool_left_it
    _run()
    accrue(date(2026, 12, 31), by='t', now=NOW, dry_run=False)
    assert [_month_expense(b['rent_account'], m) for m in ('2026-11', '2026-12')] == [10500.0, 10500.0]
    second = PeriodExpense.query.filter_by(description='إيجار المعرض يوليو–ديسمبر 2026').one()
    assert values(second, date(2026, 12, 31))['accrued'] == 63000.0


def test_the_december_voucher_with_its_tax_invoice_settles_the_second_half_net(
        auth_headers, as_the_2026_tool_left_it, vat_mapped):
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    b = as_the_2026_tool_left_it
    _run()
    accrue(date(2026, 11, 30), by='t', now=NOW, dry_run=False)
    second = PeriodExpense.query.filter_by(description='إيجار المعرض يوليو–ديسمبر 2026').one()
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers, json={
        'voucher_type': 'payment', 'date': '2026-12-10T00:00:00', 'party_type': 'other', 'description': 'إيجار',
        'account_lines': [
            {'account_id': b['rent_account'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 72450,
             'period_expense_id': second.id},
            {'account_id': b['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': 72450}],
        'expense_vat': {'amount': 9450, 'supplier_name': 'المؤجر', 'supplier_tax_number': '300000000000003',
                        'invoice_number': 'R-2026-H2', 'invoice_date': '2026-12-10'}})
    assert resp.status_code == 201, resp.get_json()
    vat = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'vat_receivable')
    # July-November owed (52,500) paid off, December ahead (10,500); the VAT on the input VAT, its invoice's
    assert debits(resp.get_json()['id']) == {(b['accrued'], 52500.0), (b['prepaid'], 10500.0), (vat, 9450.0)}


def test_a_dry_run_writes_nothing_and_a_second_run_writes_nothing(as_the_2026_tool_left_it):
    entries = JournalEntry.query.count()
    plan = _run(dry_run=True)
    rows = {r['month']: r for r in plan['before_after']}
    assert (rows['2026-07']['before']['expense'], rows['2026-07']['after']['expense']) == (12075.0, 10500.0)
    assert JournalEntry.query.count() == entries and PeriodExpense.query.count() == 1
    _run()
    entries = JournalEntry.query.count()
    assert _run().get('already') and JournalEntry.query.count() == entries


def test_the_december_voucher_linked_before_it_refuses_it(auth_headers, as_the_2026_tool_left_it):
    b = as_the_2026_tool_left_it
    assert pay(auth_headers, b, b['rent'], 1000, date(2026, 11, 2)).status_code == 201
    with pytest.raises(PlanRefused):
        _run()


def test_a_closed_month_refuses_it_whole(as_the_2026_tool_left_it):
    from services.period_lock import move
    move(date(2026, 8, 31), reason='t', by='t', now=NOW, accept_pending=True)
    entries = JournalEntry.query.count()
    with pytest.raises(PlanRefused):
        _run()
    assert JournalEntry.query.count() == entries


def test_the_owners_figures():
    figures = json.load(open(FIGURES, encoding='utf-8'))
    assert figures['rent']['amount'] == figures['first_half']['amount'] + figures['second_half']['amount'] + 9450
    assert (figures['first_half']['end'], figures['second_half']['start']) == ('2026-06-30', '2026-07-01')
