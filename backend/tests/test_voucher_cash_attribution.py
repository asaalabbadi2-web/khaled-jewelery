"""A supplier voucher's cash can be attributed to an invoice -- after the fact, as its gold can (the owner, 2 Oct 2026).

PV-2026-01222 paid 1,150 of wages for purchase #187 (invoice 3133) as a
general supplier settlement: the books were right, the invoice stayed
«partially paid» with no way to say which payment settled it. The gold side
has had «نسب ذهب السند إلى فاتورة» since Phase 16; the cash side had nothing.

The law, the gold tool's mirror: the attribution records an InvoicePayment
whose source is the voucher -- the books do not move -- and recomputes the
invoice. Guards: an approved voucher, a standing invoice, the same supplier,
no more than the voucher's unattributed cash, no more than the invoice's open
cash obligation. It can be undone; a voucher's own invoice payment cannot (the
voucher is cancelled instead); cancelling the voucher un-counts it. Same
permission as the gold tool (the owner).

Run:
    python -m pytest tests/test_voucher_cash_attribution.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Invoice, InvoicePayment, Supplier, Voucher, db
from tests.voucher_world import auto_post, create, payload, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture(autouse=True)
def cash_method(rollback_after_each):
    """Production has a cash payment method; a voucher's cash payment is recorded on it."""
    from models import PaymentMethod
    if PaymentMethod.query.filter_by(payment_type='cash').first() is None:
        db.session.add(PaymentMethod(payment_type='cash', name='نقدي', commission_rate=0.0, is_active=True))
        db.session.flush()


def _purchase(supplier_id, *, wages=1150.0):
    """A posted worked-gold purchase owing *wages* in cash (as 3133 does)."""
    inv = Invoice(invoice_type_id=800000 + uuid.uuid4().int % 99999, invoice_type='شراء', gold_type='new',
                  supplier_id=supplier_id, date=datetime.now(), total=10527.2, gold_subtotal=9377.2,
                  wage_subtotal=wages, status='unpaid', amount_paid=0.0, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    return inv


def _cash_payment(headers, w, amount):
    auto_post(True)
    resp = flask_app.test_client().post('/api/vouchers', headers=headers,
                                        json=payload(w, 'cash_payment', amount=amount))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return db.session.get(Voucher, resp.get_json()['id'])


def _attribute(headers, voucher_id, invoice_id, amount):
    return flask_app.test_client().post(f'/api/vouchers/{voucher_id}/cash-attribution', headers=headers,
                                        json={'invoice_id': invoice_id, 'amount': amount})


def _status(invoice_id):
    db.session.expire_all()
    return db.session.get(Invoice, invoice_id).status


def test_a_general_payment_attributed_to_its_invoice_pays_it(auth_headers, vworld):
    inv = _purchase(vworld['supplier'])
    v = _cash_payment(auth_headers, vworld, 1150.0)
    resp = _attribute(auth_headers, v.id, inv.id, 1150.0)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert _status(inv.id) == 'paid'
    p = InvoicePayment.query.filter_by(invoice_id=inv.id).one()
    assert (p.source_voucher_id, p.amount) == (v.id, 1150.0)


def test_part_of_a_payment_to_one_invoice_and_the_rest_to_another(auth_headers, vworld):
    a, b = _purchase(vworld['supplier'], wages=700.0), _purchase(vworld['supplier'], wages=800.0)
    v = _cash_payment(auth_headers, vworld, 1500.0)
    assert _attribute(auth_headers, v.id, a.id, 700.0).status_code == 201
    assert _attribute(auth_headers, v.id, b.id, 800.0).status_code == 201
    assert (_status(a.id), _status(b.id)) == ('paid', 'paid')


@pytest.mark.parametrize('case', ('more_than_the_voucher', 'more_than_the_invoice_owes', 'another_supplier',
                                  'an_unposted_invoice'))
def test_what_the_payment_cannot_prove_is_refused(auth_headers, vworld, case):
    inv = _purchase(vworld['supplier'])
    v = _cash_payment(auth_headers, vworld, 1000.0)
    amount = {'more_than_the_voucher': 1001.0, 'more_than_the_invoice_owes': 1000.0}.get(case, 500.0)
    if case == 'more_than_the_invoice_owes':
        inv.wage_subtotal = 900.0
    if case == 'another_supplier':
        other = Supplier(supplier_code=f'S-{uuid.uuid4().hex[:6]}', name='مورد آخر')
        db.session.add(other)
        db.session.flush()
        inv.supplier_id = other.id
    if case == 'an_unposted_invoice':
        inv.is_posted = False
    db.session.flush()
    resp = _attribute(auth_headers, v.id, inv.id, amount)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert InvoicePayment.query.filter_by(invoice_id=inv.id).count() == 0


def test_an_attribution_can_be_undone(auth_headers, vworld):
    inv = _purchase(vworld['supplier'])
    v = _cash_payment(auth_headers, vworld, 1150.0)
    pid = _attribute(auth_headers, v.id, inv.id, 1150.0).get_json()['payment']['id']
    resp = flask_app.test_client().delete(f'/api/vouchers/{v.id}/cash-attribution/{pid}', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _status(inv.id) == 'unpaid'
    assert InvoicePayment.query.filter_by(invoice_id=inv.id).count() == 0


def test_cancelling_the_voucher_uncounts_its_attribution(auth_headers, vworld):
    inv = _purchase(vworld['supplier'])
    v = _cash_payment(auth_headers, vworld, 1150.0)
    _attribute(auth_headers, v.id, inv.id, 1150.0)
    resp = flask_app.test_client().post(f'/api/vouchers/{v.id}/cancel', headers=auth_headers, json={'reason': 'law'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _status(inv.id) == 'unpaid'


def test_the_screen_sees_what_is_left_on_both_sides(auth_headers, vworld):
    inv = _purchase(vworld['supplier'])
    v = _cash_payment(auth_headers, vworld, 2000.0)
    _attribute(auth_headers, v.id, inv.id, 1000.0)
    c = flask_app.test_client()
    mine = c.get(f'/api/vouchers/{v.id}/cash-attribution', headers=auth_headers).get_json()
    assert (mine['cash_capacity'], mine['attributed'], mine['unattributed']) == (2000.0, 1000.0, 1000.0)
    assert [p['invoice_id'] for p in mine['payments']] == [inv.id] and mine['payments'][0]['removable']
    assert (mine['payments'][0]['invoice_type'], mine['payments'][0]['invoice_type_id']) == ('شراء', inv.invoice_type_id)
    open_ = c.get(f'/api/suppliers/{vworld["supplier"]}/open-cash-obligations', headers=auth_headers).get_json()
    assert {r['invoice_id']: r['open_cash'] for r in open_['invoices']}[inv.id] == 150.0


def test_a_voucher_written_for_an_invoice_keeps_its_own_payment(auth_headers, vworld):
    """At creation: a supplier cash voucher that names its invoice records its
    payment on approval (the existing contract), and that payment is the
    voucher's own -- not undone here; the voucher is cancelled instead."""
    inv = _purchase(vworld['supplier'])
    auto_post(True)
    body = payload(vworld, 'cash_payment', amount=1150.0)
    body.update({'reference_type': 'invoice', 'reference_id': inv.id})
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert _status(inv.id) == 'paid'
    vid = resp.get_json()['id']
    own = InvoicePayment.query.filter_by(source_voucher_id=vid).one()
    mine = flask_app.test_client().get(f'/api/vouchers/{vid}/cash-attribution', headers=auth_headers).get_json()
    assert mine['payments'][0]['removable'] is False
    resp = flask_app.test_client().delete(f'/api/vouchers/{vid}/cash-attribution/{own.id}', headers=auth_headers)
    assert resp.status_code == 400


def test_a_voucher_of_gold_and_cash_for_an_invoice_pays_both_sides_of_it(auth_headers, vworld):
    """The owner (2 Oct 2026): a voucher written for an invoice that carries gold
    and cash attributes both to that invoice, together -- at approval."""
    from models import InvoiceGoldObligation, VoucherInvoiceGoldAttribution
    inv = _purchase(vworld['supplier'])
    inv.gold_settlement_tracked = True
    db.session.add(InvoiceGoldObligation(invoice_id=inv.id, karat=21.0, weight=10.0))
    db.session.flush()
    auto_post(True)
    body = {'voucher_type': 'payment', 'date': datetime.now().isoformat(), 'party_type': 'supplier',
            'supplier_id': vworld['supplier'], 'reference_type': 'invoice', 'reference_id': inv.id,
            'account_lines': [
                {'account_id': vworld['supplier_acc'], 'line_type': 'debit', 'amount_type': 'cash', 'amount': 1150.0},
                {'account_id': vworld['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': 1150.0},
                {'account_id': vworld['supplier_acc'], 'line_type': 'debit', 'amount_type': 'gold', 'amount': 10.0, 'karat': 21},
                {'account_id': vworld['gold'], 'line_type': 'credit', 'amount_type': 'gold', 'amount': 10.0, 'karat': 21},
            ]}
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['id']
    assert [(a.invoice_id, a.weight) for a in VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=vid)] == [(inv.id, 10.0)]
    assert [(p.invoice_id, p.amount) for p in InvoicePayment.query.filter_by(source_voucher_id=vid)] == [(inv.id, 1150.0)]
    assert _status(inv.id) == 'paid'
