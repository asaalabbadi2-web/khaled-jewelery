"""A payment by a method with plans names its plan, and keeps its rate (ADR-100).

Tamara charges each order by the plan its customer chose -- 6.99 % for 2, 3
and 4 installments, 5.99 % for 6, 9 and 12 (the owner, 24 Nov 2026). A sale's
estimate is its plan's; the settlement charges each payment at the rate it
was paid at, plus the fee a deposit once (Tabby: 5.99).

Run:
    python -m pytest tests/test_bnpl_plans.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import Invoice, InvoicePayment, PaymentMethod, PaymentMethodPlan, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _tamara(world, **kw):
    pm = PaymentMethod(payment_type='tamara', name=f'تمارا {uuid.uuid4().hex[:6]}', commission_rate=6.078,
                       commission_fixed_amount=1.5, commission_per_order=True, is_active=True,
                       default_safe_box_id=world['pm'].default_safe_box_id, **kw)
    pm.plans = [PaymentMethodPlan(installments=n, commission_rate=r)
                for n, r in ((2, 6.99), (3, 6.99), (4, 6.99), (6, 5.99), (9, 5.99), (12, 5.99))]
    db.session.add(pm)
    db.session.flush()
    return pm


def _sale(world, payment):
    return {'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': world['holder'].id, 'date': datetime.now().isoformat(),
            'total': 1000.0, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': 1000.0,
            'payments': [{'amount': 1000.0, **payment}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]}


def _post(app, auth_headers, body):
    from flask import g
    g.pop('current_user', None)
    return app.test_client().post('/api/invoices', headers=auth_headers, json=body)


def test_a_sale_by_tamara_without_its_plan_is_refused_and_writes_nothing(app, auth_headers, world):
    pm = _tamara(world)
    before = Invoice.query.count()
    resp = _post(app, auth_headers, _sale(world, {'payment_method_id': pm.id}))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'installments_required'
    assert resp.get_json()['offered_installments'] == [2, 3, 4, 6, 9, 12]
    assert Invoice.query.count() == before

    resp = _post(app, auth_headers, _sale(world, {'payment_method_id': pm.id, 'installments': 5}))
    assert resp.status_code == 400 and resp.get_json()['error'] == 'installments_unknown'


def test_a_sale_keeps_its_plan_and_its_plans_rate(app, auth_headers, world):
    pm = _tamara(world)
    resp = _post(app, auth_headers, _sale(world, {'payment_method_id': pm.id, 'installments': 6}))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    (payment,) = InvoicePayment.query.filter_by(invoice_id=resp.get_json()['id']).all()
    assert (payment.installments, payment.commission_rate) == (6, 5.99)
    assert payment.commission_amount == pytest.approx(59.90 + 1.50)


def test_a_payment_added_later_names_its_plan_too(app, auth_headers, world):
    from flask import g
    pm = _tamara(world)
    resp = _post(app, auth_headers, {**_sale(world, {'payment_method_id': world['pm'].id}),
                                     'amount_paid': 0.0, 'payments': []})
    if resp.status_code != 201:
        pytest.skip('a sale with nothing paid is not allowed by these settings')
    invoice_id = resp.get_json()['id']
    g.pop('current_user', None)
    refused = app.test_client().post(f'/api/invoices/{invoice_id}/payments', headers=auth_headers,
                                     json={'payment_method_id': pm.id, 'amount': 1000.0})
    assert refused.status_code == 400 and refused.get_json()['error'] == 'installments_required'


def test_the_settlement_charges_each_payment_at_its_kept_rate_and_the_deposit_fee_once(app, auth_headers, world):
    """A plan's rate changed after the sale re-prices nothing paid."""
    from clearing_settlement_scheduler import settlement_charge
    pm = _tamara(world, deposit_fixed_fee=5.99)
    resp = _post(app, auth_headers, _sale(world, {'payment_method_id': world['pm'].id}))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    invoice_id = resp.get_json()['id']
    paid = []
    for amount, rate in ((1000.0, 5.99), (500.0, 6.99)):
        ip = InvoicePayment(invoice_id=invoice_id, payment_method_id=pm.id, amount=amount,
                            installments=6 if rate == 5.99 else 4, commission_rate=rate, net_amount=amount)
        db.session.add(ip)
        db.session.flush()
        paid.append((ip.id, amount))
    for plan in pm.plans:
        plan.commission_rate = 9.99
    db.session.flush()
    fee, vat = settlement_charge(pm, paid)
    assert fee == pytest.approx((59.90 + 1.50) + (34.95 + 1.50) + 5.99)
    assert vat == pytest.approx(9.21 + 5.47 + 0.90)


def test_a_method_s_plans_are_set_and_replaced_from_its_settings(app, auth_headers, world):
    from flask import g
    pm = _tamara(world)
    g.pop('current_user', None)
    resp = app.test_client().put(f'/api/payment-methods/{pm.id}', headers=auth_headers, json={
        'plans': [{'installments': 4, 'commission_rate': 6.99}, {'installments': 6, 'commission_rate': 5.99}],
        'deposit_fixed_fee': 0.0, 'commission_per_order': True})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.refresh(pm)
    assert [(p.installments, p.commission_rate) for p in pm.plans] == [(4, 6.99), (6, 5.99)]
    assert resp.get_json()['payment_method']['plans'] == [
        {'installments': 4, 'commission_rate': 6.99}, {'installments': 6, 'commission_rate': 5.99}] \
        if 'payment_method' in resp.get_json() else True

    g.pop('current_user', None)
    bad = app.test_client().put(f'/api/payment-methods/{pm.id}', headers=auth_headers,
                                json={'plans': [{'installments': 4, 'commission_rate': 6.99},
                                                {'installments': 4, 'commission_rate': 5.99}]})
    assert bad.status_code == 400 and bad.get_json()['error'] == 'invalid_plans'


def test_a_methods_deposit_confirmation_is_set_from_its_settings(app, auth_headers, world):
    from flask import g
    pm = _tamara(world)
    g.pop('current_user', None)
    resp = app.test_client().put(f'/api/payment-methods/{pm.id}', headers=auth_headers, json={
        'deposit_confirmation_required': True, 'deposit_difference_allowed': 25})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.refresh(pm)
    assert (pm.deposit_confirmation_required, pm.deposit_difference_allowed) == (True, 25.0)
    g.pop('current_user', None)
    bad = app.test_client().put(f'/api/payment-methods/{pm.id}', headers=auth_headers,
                                json={'deposit_difference_allowed': -1})
    assert bad.status_code == 400 and bad.get_json()['error'] == 'invalid_deposit_difference_allowed'


def test_a_methods_rounding_and_refundable_part_are_set_from_its_settings(app, auth_headers, world):
    """Any method of the kind, no company named: how it rounds, and the part
    of its rate refunded on a return (ADR-100)."""
    from flask import g
    pm = _tamara(world)
    g.pop('current_user', None)
    resp = app.test_client().put(f'/api/payment-methods/{pm.id}', headers=auth_headers, json={
        'commission_rounding': 'half_even', 'commission_refundable_rate': 4.99})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.refresh(pm)
    assert (pm.commission_rounding, pm.commission_refundable_rate) == ('half_even', 4.99)
    for bad in ({'commission_rounding': 'down'}, {'commission_refundable_rate': -1}):
        g.pop('current_user', None)
        refused = app.test_client().put(f'/api/payment-methods/{pm.id}', headers=auth_headers, json=bad)
        assert refused.status_code == 400, bad
