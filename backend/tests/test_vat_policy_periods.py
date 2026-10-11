"""VAT is a policy in dated periods -- an invoice reads the one in force on its date (ADR-043, phase 4a).

The owner (11 Oct 2026): «مسجّلة في المدخلات والمخرجات لا، وهذا وضع مؤقت وليس
دائم». Two switches, not one «registered»: input VAT recovered, sales VAT
charged -- and temporary, so they change by adding a period, never by editing
the past. Until now sales VAT was one switch read as it is today: re-saving a
sale of March (taxed then) would be refused today, «ضريبة المبيعات معطّلة».

Seeded from the evidence: from the books' start, inputs recovered and sales
taxed; from 2 May 2026 (sales VAT stopped the evening of 1 May, SALES-VAT-1),
inputs recovered and sales untaxed.

Run:
    python -m pytest tests/test_vat_policy_periods.py -v
"""
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Settings, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture(autouse=True)
def _vat(vat_mapped):
    yield


@pytest.fixture
def periods():
    """Taxed sales until 2 May 2033, none after; inputs recovered throughout."""
    from models import VatPolicyPeriod
    VatPolicyPeriod.query.delete()
    row = Settings.query.first() or Settings()
    row.tax_enabled, row.tax_rate, row.auto_post_invoices = True, 0.15, True
    db.session.add(row)
    db.session.add_all([
        VatPolicyPeriod(effective_from=date(2033, 1, 1), input_vat_recoverable=True, sales_vat_charged=True,
                        created_by='t'),
        VatPolicyPeriod(effective_from=date(2033, 5, 2), input_vat_recoverable=True, sales_vat_charged=False,
                        created_by='t'),
    ])
    db.session.flush()


def _taxed_sale(w, day):
    payload = _payload(w, 'sale_on_credit', held=False)
    payload.update({'total': 1150.0, 'total_tax': 150.0, 'date': datetime.combine(day, datetime.min.time()).isoformat()})
    payload['items'][0].update({'price': 1150.0, 'net': 1000.0, 'selling_price': 1150.0, 'tax': 150.0})
    return payload


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def test_the_policy_in_force_on_a_day(periods):
    from services.vat_policy import policy_on
    assert policy_on(date(2033, 3, 10)) == (True, True)
    assert policy_on(date(2033, 5, 1)) == (True, True)
    assert policy_on(date(2033, 5, 2)) == (True, False)
    assert policy_on(date(2034, 1, 1)) == (True, False)


def test_a_sale_is_taxed_by_the_period_of_its_date_not_by_today(auth_headers, world, periods):
    march = _post(auth_headers, _taxed_sale(world, date(2033, 3, 10)))
    assert march.status_code == 201, march.get_json()
    june = _post(auth_headers, _taxed_sale(world, date(2033, 6, 1)))
    assert june.status_code == 400 and june.get_json()['error'] == 'sales_vat_disabled'


def test_the_switch_adds_a_period_from_today_and_the_past_stays(auth_headers, periods):
    from models import VatPolicyPeriod
    from services.vat_policy import policy_on
    client = flask_app.test_client()
    today = date.today()
    before = policy_on(today).sales_vat_charged
    resp = client.put('/api/settings', headers=auth_headers, json={'sales_vat_enabled': not before})
    assert resp.status_code == 200, resp.get_json()
    assert policy_on(today) == (True, not before)
    assert VatPolicyPeriod.query.filter_by(effective_from=today).count() == 1
    assert policy_on(date(2033, 3, 10)) == (True, True), 'the periods already set are as they were'
    got = client.get('/api/settings', headers=auth_headers).get_json()
    assert got['sales_vat_enabled'] is (not before), 'the switch reads the period in force today'
    assert today.isoformat() in [p['effective_from'] for p in got['vat_periods']]


def test_a_period_does_not_start_in_the_past(auth_headers, periods):
    resp = flask_app.test_client().post('/api/settings/vat-periods', headers=auth_headers, json={
        'effective_from': '2020-01-01', 'input_vat_recoverable': True, 'sales_vat_charged': True})
    assert resp.status_code == 400
    resp = flask_app.test_client().post('/api/settings/vat-periods', headers=auth_headers, json={
        'effective_from': date.today().isoformat(), 'input_vat_recoverable': False, 'sales_vat_charged': False})
    assert resp.status_code == 201, resp.get_json()
    from services.vat_policy import policy_on
    assert policy_on(date.today()) == (False, False)


def test_without_periods_the_old_switch_is_read():
    """A database that has none (before the migration seeds them): the company switch, inputs recovered."""
    from models import VatPolicyPeriod
    from services.vat_policy import policy_on
    VatPolicyPeriod.query.delete()
    row = Settings.query.first() or Settings()
    row.sales_vat_enabled = False
    db.session.add(row)
    db.session.flush()
    assert policy_on(date(2033, 3, 10)) == (True, False)
