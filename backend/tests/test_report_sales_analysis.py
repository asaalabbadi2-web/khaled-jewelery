"""Sales analysis: one report by employee, customer, day or month, from the documents, agreeing with the books (REPORTS ت1-2, ADR-083).

The owner, 4 Nov 2026: financial figures from the books; an analysis from
the documents, agreeing with the books in total. On the 2 Nov copy October's
sales and returns (1,394,020.10) are exactly the sales roles' net credit:
400 new gold 1,400,313.91 + 401 scrap 20,920.00 - 420 returns 27,213.81.
So the report checks it of itself: what it sums equals the net credit on
the sales roles of the mapping in its period -- a document changed after it
was posted, or an entry made by hand, says so. A withdrawn invoice is not
counted (as the weight close does). Compared, each group says its previous
period of the same length.

Run:
    python -m pytest tests/test_report_sales_analysis.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Employee, Invoice, db
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_weight_position import _post

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _sale(headers, world, when, total, weight, employee_id):
    """Posted through the real route; its seller is the recording user's employee
    (routes/invoices), so the seller is set on the document after."""
    invoice_id = _post(headers, {
        'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'date': when.isoformat(), 'total': total, 'total_weight': weight,
        'total_tax': 0.0, 'amount_paid': total, 'payments': [{'payment_method_id': world['pm'].id, 'amount': total}],
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': weight, 'price': total, 'net': total,
                   'quantity': 1, 'wage': 0, 'selling_price': total}]})
    db.session.get(Invoice, invoice_id).employee_id = employee_id
    db.session.commit()
    return invoice_id


@pytest.fixture
def sold(auth_headers, world):
    other = Employee(name=f'بائع تحليل {uuid.uuid4().hex[:6]}', employee_code=f'S{uuid.uuid4().hex[:8]}',
                     is_active=True, salary=0.0)
    db.session.add(other)
    db.session.commit()
    first = world['holder'].id
    ids = {
        'a1': _sale(auth_headers, world, D(2041, 6, 3, 10), 1000.0, 2.0, first),
        'a2': _sale(auth_headers, world, D(2041, 6, 30, 18), 500.0, 1.0, first),
        'b1': _sale(auth_headers, world, D(2041, 6, 12, 11), 300.0, 0.5, other.id),
        'may': _sale(auth_headers, world, D(2041, 5, 20, 11), 800.0, 1.5, first),
    }
    return {'first': first, 'other': other.id, **ids}


def _analysis(**kw):
    from services.reports.sales_analysis import sales_analysis
    return sales_analysis(now=D(2041, 7, 1), **kw)


def _by(report, key='group_id'):
    return {r[key]: r for r in report.rows}


def test_by_employee_it_sums_each_one_s_sales(sold):
    report = _analysis(start=dt.date(2041, 6, 1), end=dt.date(2041, 6, 30), by='employee')
    rows = _by(report)
    assert rows[sold['first']]['value'] == pytest.approx(1500.0), 'the 3rd and the 30th at 18:00'
    assert rows[sold['first']]['invoices'] == 2 and rows[sold['first']]['weight'] == pytest.approx(3.0)
    assert rows[sold['other']]['value'] == pytest.approx(300.0)
    assert report.totals['value'] == pytest.approx(1800.0) and report.totals['invoices'] == 3
    assert report.basis == 'documents'
    assert rows[sold['first']]['drill'] == {'kind': 'employee', 'id': sold['first']}


def test_it_agrees_with_the_books_and_says_when_it_does_not(sold):
    report = _analysis(start=dt.date(2041, 6, 1), end=dt.date(2041, 6, 30), by='employee')
    assert {c.key: c.ok for c in report.checks} == {'books_agree': True}, 'posted through the real route'
    db.session.get(Invoice, sold['b1']).total = 350.0          # the document changed after it was posted
    db.session.flush()
    report = _analysis(start=dt.date(2041, 6, 1), end=dt.date(2041, 6, 30), by='employee')
    assert {c.key: c.ok for c in report.checks} == {'books_agree': False}


def test_a_withdrawn_invoice_is_not_counted(sold):
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
    db.session.get(Invoice, sold['b1']).status = sorted(RETRACTED_INVOICE_STATUSES)[0]
    db.session.flush()
    report = _analysis(start=dt.date(2041, 6, 1), end=dt.date(2041, 6, 30), by='employee')
    assert sold['other'] not in _by(report)


def test_by_month_it_sums_each_month(sold):
    report = _analysis(start=dt.date(2041, 5, 1), end=dt.date(2041, 6, 30), by='month')
    rows = _by(report, 'group')
    assert rows['2041-05']['value'] == pytest.approx(800.0) and rows['2041-06']['value'] == pytest.approx(1800.0)
    day = _by(_analysis(start=dt.date(2041, 6, 1), end=dt.date(2041, 6, 30), by='day'), 'group')
    assert day['2041-06-30']['value'] == pytest.approx(500.0)


def test_compared_each_group_says_its_previous_period(sold):
    report = _analysis(start=dt.date(2041, 6, 1), end=dt.date(2041, 6, 30), by='employee', compare=True)
    row = _by(report)[sold['first']]
    assert row['prev_value'] == pytest.approx(800.0), 'May, the thirty days before'
    assert row['change'] == pytest.approx((1500.0 - 800.0) / 800.0 * 100, abs=0.01)
    assert {c.key for c in report.columns} >= {'prev_value', 'change'}
    assert _by(report)[sold['other']]['change'] is None, 'nothing before: no change to say'


def test_the_route_answers_the_contract(auth_headers, sold):
    g.pop('current_user', None)
    resp = flask_app.test_client().get(
        '/api/reports/sales-analysis?start_date=2041-06-01&end_date=2041-06-30&by=customer', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['id'] == 'sales_analysis' and body['basis'] == 'documents'
    assert body['rows'][0]['drill']['kind'] == 'customer'
    g.pop('current_user', None)
    bad = flask_app.test_client().get('/api/reports/sales-analysis?by=nothing', headers=auth_headers)
    assert bad.status_code == 400 and bad.get_json()['error'] == 'invalid_by'


def test_a_whole_month_is_compared_with_the_month_before(auth_headers, world):
    """October (31 days) against September -- not the 31 days before it, which
    took August's 31st in (953,856 for September's 936,987 on the 2 Nov copy)."""
    first = world['holder'].id
    _sale(auth_headers, world, D(2041, 7, 10, 10), 1000.0, 2.0, first)      # July, 31 days
    _sale(auth_headers, world, D(2041, 6, 15, 10), 800.0, 1.5, first)       # June
    _sale(auth_headers, world, D(2041, 5, 31, 10), 300.0, 0.5, first)       # the 31 days before July take it
    report = _analysis(start=dt.date(2041, 7, 1), end=dt.date(2041, 7, 31), by='employee', compare=True)
    assert _by(report)[first]['prev_value'] == pytest.approx(800.0), 'June alone'
    from services.reports.sales_analysis import previous_period
    assert previous_period(dt.date(2041, 7, 1), dt.date(2041, 7, 31)) == (dt.date(2041, 6, 1), dt.date(2041, 6, 30))
    assert previous_period(dt.date(2041, 1, 1), dt.date(2041, 3, 31)) == (dt.date(2040, 10, 1), dt.date(2040, 12, 31))
    assert previous_period(dt.date(2041, 7, 5), dt.date(2041, 7, 11)) == (dt.date(2041, 6, 28), dt.date(2041, 7, 4))
