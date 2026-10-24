"""A return after its sale's bonus was paid is taken from the next period's (bonus study م4).

The owner (24 Oct 2026, among the recommendations approved): a return made
after the bonus of its sale's month was paid is deducted from the next
period -- the paid bonus stays as paid. The one measure does it (ADR-058 م1):
a return counts in the period it is made, against its sale's employee. These
witness it for a tiered rule paid on points.

Run:
    python -m pytest tests/test_return_after_payment.py -v
"""
import json
import uuid
from datetime import date, datetime

import pytest

from bonus_calculator import BonusCalculator
from models import BonusRule, Employee, EmployeeBonus, Invoice, InvoiceItem, Settings, db

MAY = (date(2031, 5, 1), date(2031, 5, 31))
JUNE = (date(2031, 6, 1), date(2031, 6, 30))


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 50.0,
                                               'points_per_gram': 10.0})
    db.session.flush()
    yield


def _employee():
    emp = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'R{uuid.uuid4().hex[:8]}', is_active=True,
                   salary=0.0)
    db.session.add(emp)
    db.session.flush()
    return emp


def _invoice(kind, emp_id, when, points, *, original=None):
    inv = Invoice(invoice_type=kind, invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=when,
                  total=10000.0, total_tax=0.0, is_posted=True, status='paid', employee_id=emp_id,
                  profit_cash=points * 50.0, total_weight=10.0,
                  original_invoice_id=original.id if original else None)
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=inv.id, name='سلسال', quantity=1, price=10000.0, karat=21.0, weight=10.0))
    db.session.flush()
    return inv


@pytest.fixture
def rule():
    rule = BonusRule(name=f'شرائح {uuid.uuid4().hex[:6]}', rule_type='tiered', bonus_type='tiers', bonus_value=0.0,
                     min_bonus=0.0, is_active=True, measure='points', period='monthly',
                     tiers=[{'from': 1000, 'per_unit': 2.5}])
    db.session.add(rule)
    db.session.flush()
    return rule


def test_a_return_after_payment_is_taken_from_the_next_month_and_the_paid_bonus_stays(rule):
    emp = _employee()
    sale = _invoice('بيع', emp.id, datetime(2031, 5, 10, 10), 1200)
    may = BonusCalculator.calculate_bonus(emp, rule, *MAY)
    assert may.amount == pytest.approx(3000.0)
    may.status = 'paid'
    db.session.add(may)
    db.session.flush()

    _invoice('بيع', emp.id, datetime(2031, 6, 10, 10), 1500)
    _invoice('مرتجع بيع', None, datetime(2031, 6, 15, 10), 1200, original=sale)

    june = BonusCalculator.calculate_bonus(emp, rule, *JUNE)
    assert june is None, '1,500 sold in June less the 1,200 returned of May: 300, below the tier'
    assert BonusCalculator.estimate(emp, rule, *MAY) == pytest.approx(3000.0), 'May is as it was'
    db.session.refresh(may)
    assert (may.status, may.amount) == ('paid', 3000.0)


def test_what_the_return_takes_is_its_sale_s_points_against_the_next_month_s(rule):
    emp = _employee()
    sale = _invoice('بيع', emp.id, datetime(2031, 5, 10, 10), 400)
    _invoice('بيع', emp.id, datetime(2031, 6, 10, 10), 2000)
    _invoice('مرتجع بيع', None, datetime(2031, 6, 15, 10), 400, original=sale)
    june = BonusCalculator.calculate_bonus(emp, rule, *JUNE)
    assert june.calculation_data['value'] == 1600
    assert june.amount == pytest.approx(1600 * 2.5)
