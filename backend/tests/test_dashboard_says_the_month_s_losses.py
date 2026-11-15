"""The manager's dashboard says the month's losing invoices, by employee (DASH-9).

The owner, 30 Oct 2026, agreeing to all advised: the dashboard said nothing of
the employees. Who leads is the race's own reading; this is the losses
themselves -- a posted sale or customer purchase whose cash profit is below
nothing, each its employee's by the points' own attribution.

Run:
    python -m pytest tests/test_dashboard_says_the_month_s_losses.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import Invoice, db
from tests.test_bonus_money_safety import _employee


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _deficits(app, headers):
    return app.test_client().get('/api/dashboard/admin/standing', headers=headers).get_json()['deficits']


def _invoice(invoice_type, profit, employee, posted=True):
    db.session.add(Invoice(invoice_type=invoice_type, invoice_type_id=10**8 + uuid.uuid4().int % 10**8,
                           date=datetime.now(), total=1000.0, profit_cash=profit, is_posted=posted,
                           employee_id=employee.id))
    db.session.flush()


def test_each_loss_is_its_employee_s(app, auth_headers):
    before = _deficits(app, auth_headers)
    seller = _employee()
    _invoice('بيع', -120.0, seller)                    # a loss
    _invoice('شراء من عميل', -30.0, seller)            # a purchase's loss
    _invoice('بيع', 200.0, seller)                     # a profit: not a loss
    _invoice('بيع', -500.0, seller, posted=False)      # held: not yet the books'
    after = _deficits(app, auth_headers)

    assert after['count'] - before['count'] == 2
    assert after['loss_cash'] - before['loss_cash'] == pytest.approx(-150.0)
    mine = next(e for e in after['employees'] if e['id'] == seller.id)
    assert (mine['count'], mine['loss_cash']) == (2, -150.0)


def test_an_invoice_with_no_employee_is_said_so_not_an_employee(app, auth_headers):
    """15 Nov 2026: «admin» stood among the employees, its id -100729354 -- a
    made-up one for the user who posted an invoice no employee holds."""
    db.session.add(Invoice(invoice_type='بيع', invoice_type_id=10**8 + uuid.uuid4().int % 10**8,
                           date=datetime.now(), total=1000.0, profit_cash=-27.0, is_posted=True,
                           employee_id=None, posted_by='admin'))
    db.session.flush()
    rows = [e for e in _deficits(app, auth_headers)['employees'] if e.get('no_employee')]
    assert rows and rows[0]['id'] is None
    assert rows[0]['name'] == 'بلا موظف — سجّلها admin'
    assert all(e['id'] is None or e['id'] > 0 for e in _deficits(app, auth_headers)['employees'])
