"""BONUS-BOOKS-1: what an employee is owed is the books' -- beside their approved bonuses.

On the production copy (14 Oct 2026) the bonuses said 14,135.00 approved and
unpaid, the books 13,660.00 -- and per employee far apart: a payment voucher's
reversal returned 6,440.00 to one employee's account and 3,047.50 to another's,
two manual entries took 2,512.50 and 2,000.00 off two others, none passing
through a bonus's status. The owner: the books are right. The screen reads the
owed amount from the books and shows the difference; no voucher is attributed
to a bonus by guess.
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, Employee, EmployeeBonus, JournalEntry, JournalEntryLine, db

NOW = datetime(2026, 10, 14, 10, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _employee_with_account():
    uid = uuid.uuid4().hex[:6]
    employee = Employee(employee_code=f'E-{uid}', name=f'موظف {uid}', is_active=True)
    account = Account(account_number=f'2310{uid}', name=f'ح/ذمم الموظف موظف {uid} - مكافآت', type='Liability')
    db.session.add_all([employee, account])
    db.session.flush()
    from services.employee_accounts import link
    link(employee, 'bonus_payable', account, by='t')       # explicit, as production's (CHART-002)
    return employee, account


def _entry(account, *, credit=0.0, debit=0.0, ref=None):
    je = JournalEntry(entry_number=f'JE-O-{uuid.uuid4().hex[:8]}', date=NOW, description='مكافأة',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t', reference_type=ref)
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='مكافأة',
                                    cash_credit=credit, cash_debit=debit))
    db.session.flush()


def _approved(employee, amount):
    db.session.add(EmployeeBonus(employee_id=employee.id, bonus_type='sales', amount=amount, status='approved',
                                 period_start=date(2026, 10, 1), period_end=date(2026, 10, 31)))
    db.session.flush()


def _row(headers, employee):
    resp = flask_app.test_client().get('/api/bonuses/owed', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    rows = [r for r in resp.get_json()['employees'] if r['employee_id'] == employee.id]
    return rows[0] if rows else None


def test_a_manual_entry_moves_the_owed_amount_not_the_bonus(app, auth_headers):
    employee, account = _employee_with_account()
    _approved(employee, 2512.50)
    _entry(account, credit=2512.50, ref='voucher')     # the approval
    _entry(account, debit=2512.50)                      # paid by a manual entry
    row = _row(auth_headers, employee)
    assert row['approved_unpaid'] == pytest.approx(2512.50)
    assert row['owed_in_books'] == pytest.approx(0.0)
    assert row['difference'] == pytest.approx(2512.50)


def test_a_reversed_payment_is_owed_again(app, auth_headers):
    employee, account = _employee_with_account()
    _entry(account, credit=6440.0, ref='voucher')            # approved
    _entry(account, debit=6440.0, ref='voucher')             # paid
    _entry(account, credit=6440.0, ref='voucher_reversal')   # the payment reversed
    row = _row(auth_headers, employee)
    assert row['owed_in_books'] == pytest.approx(6440.0)
    assert row['approved_unpaid'] == pytest.approx(0.0)


def test_the_payables_report_carries_it(app, auth_headers):
    employee, account = _employee_with_account()
    _entry(account, credit=100.0, ref='voucher')
    body = flask_app.test_client().get('/api/bonuses/payables-report', headers=auth_headers).get_json()
    assert any(r['employee_id'] == employee.id and r['owed_in_books'] == pytest.approx(100.0)
               for r in body['owed_by_employee'])
