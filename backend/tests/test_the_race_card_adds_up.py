"""The performance race card adds up (the owner, 20 Oct 2026: «تأكد أن الإجماليات
في بطاقة سباق الأداء تعرض الأرقام الصحيحة»).

Measured on the 17 Oct copy: the card's «مبلغ المبيعات» summed the sales and
left their returns out -- 607,980.10 for October against 605,759.10 in the
employees' cards beneath it, the 2,221 of the month's four returns, which each
seller's card takes back (ADR-041). And a card's sales and purchase points,
each rounded alone, did not make its total: 122 + 6 under 127.

The law: the card's sales are the sales less their returns in the period --
the sum of the employees' cards; an employee's sales and purchase points add
up to the points shown.

Run:
    python -m pytest tests/test_the_race_card_adds_up.py -v
"""
import json
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Employee, Invoice, Settings, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def race():
    """Points from riyals' profit, 100 a point."""
    settings = Settings.query.first()
    settings.sales_race_settings = json.dumps({'points_source': 'profit_cash', 'cash_amount_per_point': 100.0})
    db.session.flush()


def _employee():
    e = Employee(employee_code=f'E-RC-{uuid.uuid4().hex[:6]}', name=f'بائع {uuid.uuid4().hex[:4]}', is_active=True)
    db.session.add(e)
    db.session.flush()
    return e


def _invoice(employee, invoice_type, total, *, profit_cash=0.0, profit_gold=0.0, original=None):
    inv = Invoice(invoice_type_id=uuid.uuid4().int % 10**8, invoice_type=invoice_type, employee_id=employee.id,
                  date=datetime.now(), total=total, is_posted=True, profit_cash=profit_cash,
                  profit_gold=profit_gold, original_invoice_id=original.id if original else None)
    db.session.add(inv)
    db.session.flush()
    return inv


def _race(headers):
    resp = flask_app.test_client().get('/api/home/leaderboard', headers=headers,
                                       query_string={'period': 'today', 'metric': 'points'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def _card_less_rows(body):
    """The card's sales less its cards' -- what other tests left today stays as it was."""
    return body['admin_summary']['total_sales_amount'] - sum(r['sales_amount'] for r in body['ranking'])


def test_the_cards_sales_are_its_employees_sales_less_returns(auth_headers, race):
    before = _race(auth_headers)
    seller, other = _employee(), _employee()
    sale = _invoice(seller, 'بيع', 5000.0, profit_cash=1000.0)
    _invoice(other, 'بيع', 3000.0, profit_cash=600.0)
    _invoice(seller, 'مرتجع بيع', 5000.0, original=sale)
    after = _race(auth_headers)
    assert _card_less_rows(after) == pytest.approx(_card_less_rows(before))
    assert after['admin_summary']['total_sales_amount'] - before['admin_summary']['total_sales_amount'] \
        == pytest.approx(3000.0)
    assert after['admin_summary']['total_points'] == sum(int(r['score']) for r in after['ranking'])


def test_an_employees_sales_and_purchase_points_make_its_points(auth_headers, race):
    seller = _employee()
    _invoice(seller, 'بيع', 1000.0, profit_cash=145.0)                    # 1.45 points
    _invoice(seller, 'شراء من عميل', 500.0, profit_cash=145.0)           # 1.45 points
    (row,) = [r for r in _race(auth_headers)['ranking'] if r['id'] == seller.id]
    assert row['points_sales'] + row['points_purchase'] == int(row['score'])
