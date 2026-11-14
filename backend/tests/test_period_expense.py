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
from models import Account, db
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

from tests.period_expense_world import books, debits as _debits, expense, pay as _pay  # noqa: F401,E402


def _expense(books, **kw):
    return expense(books, **kw)


def test_the_june_rent_pays_off_what_the_books_accrued_and_the_rest_is_prepaid(auth_headers, books):
    """The split reads the books, not the schedule: January to May posted as
    accrued, the payment of 24 June pays them off and puts June prepaid."""
    from services.period_expense import accrue
    auto_post(True)
    rent = _expense(books)
    accrue(date(2026, 5, 31), by='tester', now=datetime(2026, 6, 1), dry_run=False)
    resp = _pay(auth_headers, books, rent, 72450, date(2026, 6, 24))
    assert resp.status_code == 201, resp.get_json()
    assert _debits(resp.get_json()['id']) == {(books['accrued'], 60375.0), (books['prepaid'], 12075.0)}
    assert values(rent, date(2026, 6, 24))['balance'] == 12075.0
    assert values(rent, date(2026, 6, 30))['standing'] == 'settled'
    assert values(rent, date(2026, 12, 30)) == {
        'accrued': 132825.0, 'paid': 72450.0, 'balance': -60375.0, 'standing': 'accrued',
        'amount': 144900.0, 'remaining_to_pay': 72450.0}


def test_a_payment_with_nothing_posted_yet_is_prepaid_whatever_the_schedule(auth_headers, books):
    """No month posted, the books carry no accrued balance to pay off: the
    whole payment prepaid; the months, posted later, draw it down (law 4)."""
    auto_post(True)
    rent = _expense(books)
    resp = _pay(auth_headers, books, rent, 72450, date(2026, 6, 24))
    assert _debits(resp.get_json()['id']) == {(books['prepaid'], 72450.0)}


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


def test_a_cancelled_payment_pays_nothing_from_the_day_it_was_cancelled(auth_headers, books):
    auto_post(True)
    rent = _expense(books)
    vid = _pay(auth_headers, books, rent, 72450, date(2026, 6, 24)).get_json()['id']
    g.pop('current_user', None)
    assert flask_app.test_client().post(f'/api/vouchers/{vid}/cancel', headers=auth_headers,
                                        json={'reason': 'خطأ'}).status_code == 200
    # As the books held it: paid on 30 June, the cancellation (today) not yet
    # come; from the day it was cancelled, nothing.
    assert values(rent, date(2026, 6, 30))['paid'] == 72450.0
    assert values(rent, date.today())['paid'] == 0.0


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


def test_a_payment_with_its_tax_invoice_defers_the_net_and_claims_the_vat_on_its_day(auth_headers, books, vat_mapped):
    """The owner (14 Nov 2026): an expense of a period paid with VAT -- the VAT is
    not deferred (law 10): split off on the voucher's day by the expense-VAT
    rule (ADR-054), the net alone the period expense's payment."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    auto_post(True)
    insurance = _expense(books, amount=10000, start=date(2026, 12, 1), end=date(2027, 11, 30))
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers, json={
        'voucher_type': 'payment', 'date': '2026-11-20T00:00:00', 'party_type': 'other', 'description': 'تأمين',
        'account_lines': [
            {'account_id': books['rent_account'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 11500,
             'period_expense_id': insurance.id},
            {'account_id': books['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': 11500}],
        'expense_vat': {'amount': 1500, 'supplier_name': 'شركة التأمين', 'supplier_tax_number': '300000000000003',
                        'invoice_number': 'INS-2026-77', 'invoice_date': '2026-11-20'}})
    assert resp.status_code == 201, resp.get_json()
    vat_account = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'vat_receivable')
    assert _debits(resp.get_json()['id']) == {(books['prepaid'], 10000.0), (vat_account, 1500.0)}
    assert values(insurance, date(2026, 11, 30)) == {
        'accrued': 0.0, 'paid': 10000.0, 'balance': 10000.0, 'standing': 'prepaid',
        'amount': 10000.0, 'remaining_to_pay': 0.0}


def test_an_accrued_expense_paid_late_with_its_tax_invoice_settles_the_net_and_claims_the_vat(
        auth_headers, books, vat_mapped):
    """Accrued, then paid: the months accrue the net (no invoice yet, no VAT to
    claim); the payment with its tax invoice settles the accrued net and claims
    the VAT on its day -- nothing of the VAT ever in the expense."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from services.period_expense import accrue
    auto_post(True)
    rent = _expense(books, amount=60000, start=date(2026, 1, 1), end=date(2026, 6, 30))
    accrue(date(2026, 6, 30), by='t', now=datetime(2026, 7, 1), dry_run=False)       # six months, net, owed
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers, json={
        'voucher_type': 'payment', 'date': '2026-07-05T00:00:00', 'party_type': 'other', 'description': 'إيجار',
        'account_lines': [
            {'account_id': books['rent_account'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 69000,
             'period_expense_id': rent.id},
            {'account_id': books['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': 69000}],
        'expense_vat': {'amount': 9000, 'supplier_name': 'المؤجر', 'supplier_tax_number': '300000000000003',
                        'invoice_number': 'R-2026-H1', 'invoice_date': '2026-07-05'}})
    assert resp.status_code == 201, resp.get_json()
    vat_account = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'vat_receivable')
    assert _debits(resp.get_json()['id']) == {(books['accrued'], 60000.0), (vat_account, 9000.0)}
    assert values(rent, date(2026, 7, 31))['standing'] == 'settled'
