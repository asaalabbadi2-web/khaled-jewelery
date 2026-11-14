"""An expense of a period: its schedule, its three values, its payments (ADR-090, phase 3).

The owner (13-14 Nov 2026): the showroom's rent is 144,900 for 2026; the
voucher of 24 June (72,450) paid January to June; July to December is paid in
December. «يجب أن يستطيع النظام تمثيل ثلاث قيم مستقلة: المستحق حتى تاريخه،
المدفوع حتى تاريخه، الرصيد المتبقي ... وأن يتحول رصيده من مقدم إلى مستحق أو
العكس.» And the schedule: whole months equal, a part month by its days, in
halalas, the last month taking the rounding.

Run:
    python -m pytest tests/test_period_expense.py -v
"""
import uuid
from datetime import date, datetime
from types import SimpleNamespace

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntryLine, PeriodExpense, Voucher, db
from services.period_expense import (
    PeriodExpenseRefused, accrued_to, create, halalas, paid_to, schedule, values,
)
from tests.voucher_world import auto_post, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


# ── law 5: the schedule ────────────────────────────────────────────────────────

def test_whole_months_are_equal():
    half = schedule(72450, date(2026, 1, 1), date(2026, 6, 30))
    assert [m.amount for m in half] == [1207500] * 6
    year = schedule(144900, date(2026, 1, 1), date(2026, 12, 31))
    assert [m.amount for m in year] == [1207500] * 12
    assert [m.ends for m in year][:2] == [date(2026, 1, 31), date(2026, 2, 28)]


def test_a_part_month_goes_by_its_days_and_the_months_add_to_the_amount():
    months = schedule(1000, date(2026, 4, 15), date(2027, 4, 14))
    assert len(months) == 13
    assert months[0].amount == 4444                      # April: 16 of 30 days, of 83.33 a month
    assert {m.amount for m in months[1:-1]} == {8333}     # the whole months, equal
    assert sum(m.amount for m in months) == 100000        # exactly the amount


def test_the_last_month_takes_the_rounding():
    assert [m.amount for m in schedule(100, date(2026, 1, 1), date(2026, 3, 31))] == [3333, 3333, 3334]


def test_a_reversed_period_is_refused():
    with pytest.raises(PeriodExpenseRefused) as refused:
        schedule(100, date(2026, 3, 1), date(2026, 2, 1))
    assert refused.value.code == 'period_reversed'


# ── law 3: the three values ───────────────────────────────────────────────────

def _unsaved(amount, start, end, **kw):
    return SimpleNamespace(id=-1, amount=amount, period_start=start, period_end=end, opened_on=None,
                           accrued_before_opening=0, paid_before_opening=0, description='x', **kw)


def test_accrued_counts_the_months_over():
    rent = _unsaved(144900, date(2026, 1, 1), date(2026, 12, 31))
    assert accrued_to(rent, date(2026, 6, 23)) == halalas(60375)       # January to May
    assert accrued_to(rent, date(2026, 6, 30)) == halalas(72450)       # June over on its last day
    assert accrued_to(rent, date(2026, 6, 30), before=True) == halalas(60375)
    assert values(rent, date(2026, 6, 23)) == {
        'accrued': 60375.0, 'paid': 0.0, 'balance': -60375.0, 'standing': 'accrued',
        'amount': 144900.0, 'remaining_to_pay': 144900.0}


def test_one_carried_into_a_new_year_counts_what_came_before_its_opening():
    """Law 12: the months before the opening are the carried figures, not the schedule's."""
    licence = _unsaved(1200, date(2026, 7, 1), date(2027, 6, 30))
    licence.opened_on, licence.accrued_before_opening, licence.paid_before_opening = date(2027, 1, 1), 600, 1200
    assert accrued_to(licence, date(2027, 1, 31)) == halalas(700)
    assert paid_to(licence, date(2027, 1, 31)) == halalas(1200)


# ── the expense, and a voucher paying it (laws 2 and 4) ───────────────────────

@pytest.fixture
def books(vworld):
    from services.repair.period_expense_accounts import setup
    setup(by='test', prepaid_under='1', accrued_under='2', dry_run=False)
    parent = Account.query.filter_by(account_number='540').one()
    rent_account = Account(account_number=f'54{uuid.uuid4().int % 10**6:06d}', name='إيجار المعرض', type='Expense',
                           transaction_type='cash', parent_id=parent.id)
    db.session.add(rent_account)
    db.session.flush()
    from accounting.chart_tree import role_account_id
    return {**vworld, 'rent_account': rent_account.id,
            'prepaid': role_account_id('prepaid_expenses'), 'accrued': role_account_id('accrued_expenses')}


def _expense(books, amount=144900, start=date(2026, 1, 1), end=date(2026, 12, 31)):
    return create(description='إيجار المعرض 2026', expense_account_id=books['rent_account'], amount=amount,
                  period_start=start, period_end=end, by='tester', now=datetime(2026, 1, 1))


def _pay(headers, books, pe, amount, day, *, voucher_type='payment', amount_type='cash', account=None):
    g.pop('current_user', None)
    line = {'account_id': account or books['rent_account'], 'line_type': 'debit', 'amount_type': amount_type,
            'amount': amount, 'period_expense_id': pe.id}
    if amount_type == 'gold':
        line['karat'] = 21
    counter = {'account_id': books['cash'] if amount_type == 'cash' else books['gold'], 'line_type': 'credit',
               'amount_type': amount_type, 'amount': amount, **({'karat': 21} if amount_type == 'gold' else {})}
    return flask_app.test_client().post('/api/vouchers', headers=headers, json={
        'voucher_type': voucher_type, 'date': datetime.combine(day, datetime.min.time()).isoformat(),
        'description': 'إيجار', 'account_lines': [line, counter]})


def _debits(voucher_id):
    entry = db.session.get(Voucher, voucher_id).journal_entry_id
    return {(l.account_id, round(l.cash_debit or 0, 2)) for l in
            JournalEntryLine.query.filter_by(journal_entry_id=entry) if (l.cash_debit or 0) > 0}


def test_the_june_rent_pays_off_what_accrued_and_the_rest_is_prepaid(auth_headers, books):
    auto_post(True)
    rent = _expense(books)
    resp = _pay(auth_headers, books, rent, 72450, date(2026, 6, 24))
    assert resp.status_code == 201, resp.get_json()
    # January to May accrued (60,375) paid off; June's 12,075 paid before it is over: prepaid.
    assert _debits(resp.get_json()['id']) == {(books['accrued'], 60375.0), (books['prepaid'], 12075.0)}
    assert values(rent, date(2026, 6, 24))['balance'] == 12075.0
    assert values(rent, date(2026, 6, 30))['standing'] == 'settled'
    assert values(rent, date(2026, 12, 30)) == {
        'accrued': 132825.0, 'paid': 72450.0, 'balance': -60375.0, 'standing': 'accrued',
        'amount': 144900.0, 'remaining_to_pay': 72450.0}


def test_a_payment_before_the_period_is_all_prepaid(auth_headers, books):
    auto_post(True)
    licence = _expense(books, amount=1200, start=date(2026, 12, 1), end=date(2027, 11, 30))
    resp = _pay(auth_headers, books, licence, 1200, date(2026, 11, 20))
    assert resp.status_code == 201, resp.get_json()
    assert _debits(resp.get_json()['id']) == {(books['prepaid'], 1200.0)}


def test_a_payment_beyond_the_amount_is_refused(auth_headers, books):
    auto_post(True)
    rent = _expense(books, amount=72450, start=date(2026, 1, 1), end=date(2026, 6, 30))
    assert _pay(auth_headers, books, rent, 72450, date(2026, 6, 24)).status_code == 201
    over = _pay(auth_headers, books, rent, 1, date(2026, 6, 25))
    assert over.status_code == 400 and over.get_json()['error'] == 'overpaid_period_expense', over.get_json()


def test_a_pending_payment_is_checked_again_when_approved(auth_headers, books):
    auto_post(False)
    rent = _expense(books, amount=72450, start=date(2026, 1, 1), end=date(2026, 6, 30))
    first = _pay(auth_headers, books, rent, 72450, date(2026, 6, 24)).get_json()['id']
    second = _pay(auth_headers, books, rent, 72450, date(2026, 6, 25)).get_json()['id']   # pending: both fit alone
    g.pop('current_user', None)
    assert flask_app.test_client().post(f'/api/vouchers/{first}/approve', headers=auth_headers, json={}).status_code == 200
    g.pop('current_user', None)
    refused = flask_app.test_client().post(f'/api/vouchers/{second}/approve', headers=auth_headers, json={})
    assert refused.status_code == 400 and 'يتجاوز المبلغ' in str(refused.get_json()), refused.get_json()


def test_a_cancelled_payment_pays_nothing(auth_headers, books):
    auto_post(True)
    rent = _expense(books)
    vid = _pay(auth_headers, books, rent, 72450, date(2026, 6, 24)).get_json()['id']
    g.pop('current_user', None)
    assert flask_app.test_client().post(f'/api/vouchers/{vid}/cancel', headers=auth_headers,
                                        json={'reason': 'خطأ'}).status_code == 200
    assert values(rent, date(2026, 6, 30))['paid'] == 0.0


@pytest.mark.parametrize('kind, code', [
    ('receipt', 'period_expense_line'),
    ('gold', 'period_expense_line'),
    ('other_account', 'period_expense_account'),
])
def test_a_line_naming_an_expense_is_its_payment_or_refused(auth_headers, books, kind, code):
    auto_post(True)
    rent = _expense(books)
    if kind == 'receipt':
        resp = _pay(auth_headers, books, rent, 100, date(2026, 6, 24), voucher_type='receipt')
    elif kind == 'gold':
        resp = _pay(auth_headers, books, rent, 1, date(2026, 6, 24), amount_type='gold')
    else:
        resp = _pay(auth_headers, books, rent, 100, date(2026, 6, 24), account=books['supplier_acc'])
    assert resp.status_code == 400 and resp.get_json()['error'] == code, resp.get_json()


def test_unmapped_accounts_refuse_the_payment_by_name(auth_headers, vworld):
    auto_post(True)
    parent = Account.query.filter_by(account_number='540').one()
    acc = Account(account_number=f'54{uuid.uuid4().int % 10**6:06d}', name='رخصة', type='Expense',
                  transaction_type='cash', parent_id=parent.id)
    db.session.add(acc)
    db.session.flush()
    pe = create(description='رخصة', expense_account_id=acc.id, amount=100, period_start=date(2026, 1, 1),
                period_end=date(2026, 12, 31), by='t', now=datetime(2026, 1, 1))
    resp = _pay(auth_headers, {**vworld, 'rent_account': acc.id}, pe, 100, date(2026, 6, 1))
    assert resp.status_code == 400 and resp.get_json()['error'] == 'period_expense_accounts_not_mapped', resp.get_json()


# ── creating one ──────────────────────────────────────────────────────────────

def test_the_route_creates_one_and_reads_its_values(auth_headers, books):
    client = flask_app.test_client()
    g.pop('current_user', None)
    made = client.post('/api/period-expenses', headers=auth_headers, json={
        'description': 'إيجار المعرض 2026', 'expense_account_id': books['rent_account'], 'amount': 144900,
        'period_start': '2026-01-01', 'period_end': '2026-12-31'})
    assert made.status_code == 201, made.get_json()
    g.pop('current_user', None)
    read = client.get(f"/api/period-expenses/{made.get_json()['id']}?as_of=2026-06-23", headers=auth_headers).get_json()
    assert read['accrued'] == 60375.0 and read['standing'] == 'accrued' and len(read['schedule']) == 12


@pytest.mark.parametrize('change, code', [
    ({'period_end': '2025-12-31'}, 'period_reversed'),
    ({'amount': 0}, 'amount_not_positive'),
    ({'description': ' '}, 'description_required'),
    ({'expense_account_id': 'cash'}, 'not_an_expense_account'),
])
def test_the_route_refuses_what_is_not_an_expense_of_a_period(auth_headers, books, change, code):
    body = {'description': 'إيجار', 'expense_account_id': books['rent_account'], 'amount': 100,
            'period_start': '2026-01-01', 'period_end': '2026-12-31', **change}
    if body['expense_account_id'] == 'cash':
        body['expense_account_id'] = books['cash']
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/period-expenses', headers=auth_headers, json=body)
    assert resp.status_code == 400 and resp.get_json()['error'] == code, resp.get_json()


# ── the accounts ──────────────────────────────────────────────────────────────

def test_the_accounts_are_made_and_mapped_once_and_a_dry_run_makes_nothing(app):
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from services.repair.period_expense_accounts import setup
    plan = setup(by='t', prepaid_under='1', accrued_under='2', dry_run=True)
    assert [m['role'] for m in plan['made']] == ['prepaid_expenses', 'accrued_expenses']
    assert get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'prepaid_expenses') is None
    setup(by='t', prepaid_under='1', accrued_under='2', dry_run=False)
    prepaid = db.session.get(Account, get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'prepaid_expenses'))
    accrued = db.session.get(Account, get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'accrued_expenses'))
    assert (prepaid.type, accrued.type) == ('Asset', 'Liability')
    assert setup(by='t', prepaid_under='1', accrued_under='2', dry_run=False)['kept'] == [
        'prepaid_expenses', 'accrued_expenses']
