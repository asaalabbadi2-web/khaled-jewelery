"""The manager's dashboard says what waits for the manager (DASH-6).

The owner, 30 Oct 2026, agreeing to all advised: the dashboard said how many
invoices are unposted -- a rejected one counted as waiting -- and nothing of
the vouchers, the bonuses or the offices' reservations that wait as well. Each
queue now by its own screen's reading: a rejected invoice does not wait, nor
does a pending voucher with an entry (V0's legacy, waiting for repair).

Run:
    python -m pytest tests/test_dashboard_says_what_waits_for_the_manager.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import EmployeeBonus, Invoice, JournalEntry, Voucher, db
from tests.test_bonus_money_safety import _employee


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _dashboard(app, headers):
    return app.test_client().get('/api/dashboard/admin/standing', headers=headers).get_json()


def _approvals(app, headers):
    return _dashboard(app, headers)['approvals']


def _invoice(total, **kw):
    inv = Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=datetime.now(),
                  total=total, is_posted=False, **kw)
    db.session.add(inv)
    db.session.flush()


def _voucher(cash, **kw):
    db.session.add(Voucher(voucher_number=f'V-A-{uuid.uuid4().hex[:8]}', voucher_type='payment',
                           date=datetime.now(), amount_cash=cash, status='pending', **kw))
    db.session.flush()


def test_each_queue_waits_by_its_own_reading(app, auth_headers):
    before = _approvals(app, auth_headers)

    _invoice(1500.0)                                   # held: waits
    _invoice(900.0, status='rejected')                 # rejected: does not
    _voucher(400.0)                                    # pending: waits
    je = JournalEntry(entry_number=f'JE-A-{uuid.uuid4().hex[:8]}', date=datetime.now(), description='قديم',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    _voucher(700.0, journal_entry_id=je.id)            # V0's legacy: waits for repair, not approval
    db.session.add(EmployeeBonus(employee_id=_employee().id, bonus_type='sales', amount=250.0, status='pending'))
    db.session.flush()

    after = _approvals(app, auth_headers)

    def moved(queue):
        return (after[queue]['count'] - before[queue]['count'],
                round(after[queue]['amount'] - before[queue]['amount'], 2))
    assert moved('invoices') == (1, 1500.0)
    assert moved('vouchers') == (1, 400.0)
    assert moved('bonuses') == (1, 250.0)
    assert after['total'] - before['total'] == 3
