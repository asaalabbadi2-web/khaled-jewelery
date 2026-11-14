"""2026's expenses of a period, put in their months (ADR-090, phase 8).

The owner (13-14 Nov 2026): the rent is 144,900 for 2026; the voucher of 24
June paid January to June. «اعتبر جميع الرخص وغيرها محصورة بسنة ٢٠٢٦» --
«على السنة كلها». The tool makes each a period expense, links its voucher as
a payment, corrects the voucher's day from expense to accrued or prepaid, and
accrues the months -- in time order, so each split is right the first time.
Synthetic books here; the owner's figures are the data file, checked apart.

Run:
    python -m pytest tests/test_period_expense_2026.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, PeriodExpense, VoucherAccountLine, db
from services.period_expense import _ledger_balance, riyals
from services.repair.period_expense_2026 import FIGURES, PAYMENT_CORRECTION, PlanRefused, apply
from tests.period_expense_world import books  # noqa: F401 (fixture)
from tests.voucher_world import auto_post, vworld  # noqa: F401 (fixture)

NOW = datetime(2026, 11, 14, 10, 0)
OCTOBER = date(2026, 10, 31)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _voucher(headers, books, account_id, amount, day):
    """A payment to «آخر» on an expense, as the shop booked them: no period expense named."""
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/vouchers', headers=headers, json={
        'voucher_type': 'payment', 'date': datetime.combine(day, datetime.min.time()).isoformat(),
        'description': 'مصروف', 'account_lines': [
            {'account_id': account_id, 'line_type': 'debit', 'amount_type': 'cash', 'amount': amount},
            {'account_id': books['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': amount}]})
    assert resp.status_code == 201, resp.get_json()
    return resp.get_json()['voucher_number']


@pytest.fixture
def shop(auth_headers, books):
    """The rent paid on 24 June for January to June; a licence on 21 October."""
    auto_post(True)
    parent = Account.query.filter_by(account_number='540').one()
    licences = Account(account_number=f'54{uuid.uuid4().int % 10**6:06d}', name='رسوم تجديد رخص العمل',
                       type='Expense', transaction_type='cash', parent_id=parent.id)
    db.session.add(licences)
    db.session.flush()
    rent_account = db.session.get(Account, books['rent_account'])
    rent_voucher = _voucher(auth_headers, books, rent_account.id, 72450, date(2026, 6, 24))
    licence_voucher = _voucher(auth_headers, books, licences.id, 7762, date(2026, 10, 21))
    figures = {'expenses': [
        {'key': 'rent_2026', 'description': 'إيجار المعرض 2026',
         'account': {'number': rent_account.account_number, 'name': rent_account.name},
         'amount': 144900, 'start': '2026-01-01', 'end': '2026-12-31',
         'vouchers': [{'number': rent_voucher, 'amount': 72450}]},
        {'key': 'iqama_2026', 'description': 'إقامة صالح 2026',
         'account': {'number': licences.account_number, 'name': licences.name},
         'amount': 7762, 'start': '2026-01-01', 'end': '2026-12-31',
         'vouchers': [{'number': licence_voucher, 'amount': 7762}]},
    ]}
    return {**books, 'figures': figures, 'licences': licences.id, 'rent_voucher': rent_voucher,
            'licence_voucher': licence_voucher}


def _run(shop, dry_run=False, figures=None):
    return apply(through=OCTOBER, by='period_expense_2026', now=NOW, dry_run=dry_run,
                 figures=figures or shop['figures'])


def _balance(account_id, through=OCTOBER):
    return riyals(_ledger_balance(account_id, through))


def test_a_dry_run_shows_the_months_and_writes_nothing(shop):
    entries = JournalEntry.query.count()
    plan = _run(shop, dry_run=True)
    assert plan['applied'] is False and (JournalEntry.query.count(), PeriodExpense.query.count()) == (entries, 0)
    rows = {r['month']: r for r in plan['before_after']}
    assert rows['2026-06']['before']['expense'] == 72450.0                     # June bore the half-year
    assert rows['2026-10']['before']['expense'] == 7762.0                      # October the iqama
    # after: each month its share -- the rent's 12,075 and the iqama's 646.83 (October 646.87 is not its last)
    assert [rows[f'2026-{m:02d}']['after']['expense'] for m in (1, 6, 9)] == [12721.83] * 3


def test_the_rent_pays_off_january_to_may_and_puts_june_ahead(shop):
    plan = _run(shop)
    assert plan['applied'] and plan['reclass'] == [] and plan['drift'] == []
    june = next(c for c in plan['corrections'] if c['voucher'] == shop['rent_voucher'])
    assert {(d['account_id'], d['amount']) for d in june['debits']} == {
        (shop['accrued'], 60375.0), (shop['prepaid'], 12075.0)}
    entry = JournalEntry.query.filter_by(reference_type=PAYMENT_CORRECTION, reference_number=shop['rent_voucher']).one()
    assert entry.date.date() == date(2026, 6, 24) and entry.is_posted
    credit = JournalEntryLine.query.filter_by(journal_entry_id=entry.id, account_id=shop['rent_account']).one()
    assert credit.cash_credit == 72450.0                                       # the voucher's day nets to nothing
    rent = PeriodExpense.query.filter_by(description='إيجار المعرض 2026').one()
    line = VoucherAccountLine.query.filter_by(account_id=shop['rent_account'], line_type='debit').one()
    assert line.period_expense_id == rent.id


def test_the_books_end_october_as_the_expenses_say(shop, monkeypatch):
    import services.period_expense as period_expense
    from services.books_invariants import check_period_expense_ledger_drift, check_period_expense_months_missing
    _run(shop)
    # the rent: July-October owed (48,300); the iqama: paid in October, November and December ahead
    assert _balance(shop['accrued']) == -48300.0
    assert _balance(shop['prepaid']) == round(7762 - 10 * 646.83, 2)
    monkeypatch.setattr(period_expense, 'books_today', lambda: date(2026, 11, 14))
    assert check_period_expense_ledger_drift() == [] and check_period_expense_months_missing() == []


def test_a_second_run_writes_nothing(shop):
    _run(shop)
    entries = JournalEntry.query.count()
    again = _run(shop)
    assert again.get('already') and JournalEntry.query.count() == entries


@pytest.mark.parametrize('change', ['account_name', 'voucher_amount'])
def test_books_not_as_the_plan_found_them_refuse_it_whole(shop, change):
    figures = json.loads(json.dumps(shop['figures']))
    if change == 'account_name':
        figures['expenses'][0]['account']['name'] = 'حساب آخر'
    else:
        figures['expenses'][1]['vouchers'][0]['amount'] = 7000
    entries = JournalEntry.query.count()
    with pytest.raises(PlanRefused):
        _run(shop, figures=figures)
    assert (JournalEntry.query.count(), PeriodExpense.query.count()) == (entries, 0)


def test_a_month_already_closed_refuses_it(shop):
    from services.period_lock import move
    move(date(2026, 1, 31), reason='test', by='t', now=NOW, accept_pending=True)
    with pytest.raises(PlanRefused):
        _run(shop)


def test_the_owners_figures_are_2026_each_paid_within_its_amount():
    figures = json.load(open(FIGURES, encoding='utf-8'))
    keys = [e['key'] for e in figures['expenses']]
    assert len(keys) == len(set(keys)) == 7
    for e in figures['expenses']:
        assert (e['start'], e['end']) == ('2026-01-01', '2026-12-31'), e['key']
        assert sum(v['amount'] for v in e['vouchers']) <= e['amount'], e['key']
    rent = next(e for e in figures['expenses'] if e['key'] == 'rent_2026')
    assert (rent['amount'], rent['vouchers'][0]['amount']) == (144900, 72450)
