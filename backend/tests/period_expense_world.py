"""Period expenses for the tests (ADR-090): the two accounts made and mapped, a
rent account under the administrative expenses, an expense, a voucher paying it."""
import uuid
from datetime import date, datetime

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntryLine, Voucher, db
from services.period_expense import create
from tests.voucher_world import vworld  # noqa: F401 (fixture)


@pytest.fixture
def books(vworld):
    from accounting.chart_tree import role_account_id
    from services.repair.period_expense_accounts import setup
    setup(by='test', prepaid_under='1', accrued_under='2', dry_run=False)
    parent = Account.query.filter_by(account_number='540').one()
    rent_account = Account(account_number=f'54{uuid.uuid4().int % 10**6:06d}', name='إيجار المعرض', type='Expense',
                           transaction_type='cash', parent_id=parent.id)
    db.session.add(rent_account)
    db.session.flush()
    return {**vworld, 'rent_account': rent_account.id,
            'prepaid': role_account_id('prepaid_expenses'), 'accrued': role_account_id('accrued_expenses')}


def expense(books, amount=144900, start=date(2026, 1, 1), end=date(2026, 12, 31), description='إيجار المعرض 2026'):
    return create(description=description, expense_account_id=books['rent_account'], amount=amount,
                  period_start=start, period_end=end, by='tester', now=datetime(2026, 1, 1))


def pay(headers, books, pe, amount, day, *, voucher_type='payment', amount_type='cash', account=None):
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


def debits(voucher_id):
    entry = db.session.get(Voucher, voucher_id).journal_entry_id
    return {(l.account_id, round(l.cash_debit or 0, 2)) for l in
            JournalEntryLine.query.filter_by(journal_entry_id=entry) if (l.cash_debit or 0) > 0}
