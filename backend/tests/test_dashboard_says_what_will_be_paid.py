"""The dashboard says what the shop will pay soon (the owner, 15 Nov 2026).

«اقترح ما ينقصها» -- «طبق جميع ما اقترحت». The laws:
  - each active period expense still to pay: what is left of it, what of it
    is owed now, and its end -- its own values, not a sum of the dashboard's;
  - the salaries the employees' salary payables hold;
  - the suppliers and the VAT as their own cards say them;
  - their riyals together; a part not read leaves the whole not read.

Run:
    python -m pytest tests/test_dashboard_says_what_will_be_paid.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, Employee, EmployeeAccount, JournalEntry, JournalEntryLine, db
from services.dashboard_upcoming import upcoming
from services.period_expense import accrue
from tests.period_expense_world import books, expense  # noqa: F401 (fixture)
from tests.voucher_world import vworld  # noqa: F401 (fixture)

SUPPLIERS = {'we_owe_cash': 187260.01, 'we_owe_gold': 281.24, 'we_owe_count': 12}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _owed_salary(amount):
    """An employee whose salary payable holds *amount* for him."""
    tag = uuid.uuid4().hex[:6]
    employee = Employee(employee_code=f'E-{tag}', name=f'موظف {tag}', is_active=True)
    payable = Account(account_number=f'8{uuid.uuid4().int % 10**7:07d}', name=f'رواتب مستحقة {tag}',
                      type='Liability', transaction_type='cash', tracks_weight=False)
    db.session.add_all([employee, payable])
    db.session.flush()
    db.session.add(EmployeeAccount(employee_id=employee.id, role='salary_payable', account_id=payable.id,
                                   created_by='t'))
    je = JournalEntry(entry_number=f'JE-UP-{tag}', date=datetime(2026, 10, 31), description='راتب',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=payable.id, cash_credit=amount))
    db.session.flush()


def test_what_will_be_paid_each_by_its_reader_and_together(books):  # noqa: F811
    rent = expense(books, amount=63000, start=date(2026, 7, 1), end=date(2026, 12, 31),
                   description='إيجار المعرض يوليو–ديسمبر 2026')
    accrue(date(2026, 10, 31), by='t', now=datetime(2026, 11, 14), dry_run=False)
    _owed_salary(4200.0)
    before = upcoming(date(2026, 11, 15), suppliers=SUPPLIERS, vat_owed=1.12)
    (row,) = [e for e in before['period_expenses'] if e['id'] == rent.id]
    assert (row['to_pay'], row['owed_now'], row['by']) == (63000.0, 42000.0, '2026-12-31')
    assert before['salaries']['amount'] >= 4200.0 and before['salaries']['count'] >= 1
    assert (before['suppliers']['cash'], before['suppliers']['gold']) == (187260.01, 281.24)
    assert before['vat'] == 1.12
    whole = sum(e['to_pay'] for e in before['period_expenses']) + before['salaries']['amount'] + 187260.01 + 1.12
    assert before['total_cash'] == round(whole, 2)


def test_a_vat_due_back_is_not_a_payment(books):  # noqa: F811
    assert upcoming(date(2026, 11, 15), suppliers=SUPPLIERS, vat_owed=-500.0)['vat'] == 0.0


def test_a_part_not_read_leaves_the_whole_not_read(books):  # noqa: F811
    said = upcoming(date(2026, 11, 15), suppliers=None, vat_owed=1.12)
    assert said['suppliers']['cash'] is None and said['total_cash'] is None


def test_the_dashboard_carries_it(app, auth_headers):
    from flask import g
    g.pop('current_user', None)
    standing = app.test_client().get('/api/dashboard/admin/standing', headers=auth_headers).get_json()
    assert standing['upcoming'] is not None
    assert {'period_expenses', 'salaries', 'suppliers', 'vat', 'total_cash'} <= set(standing['upcoming'])
