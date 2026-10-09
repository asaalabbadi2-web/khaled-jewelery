"""A supplier payment goes to the invoices the employee chose, oldest first (VOUCHER-ATTR-1).

The owner (9 Oct 2026): the employee picks the invoices a payment is for; the
voucher's cash and gold are spread over them in the order of their dates, each
taking what it still owes; what is left stays on the supplier's account
(a payment on account is legitimate), and the review says how much.

Not ADR-028's forbidden auto-FIFO: nothing is attributed to an invoice the
employee did not choose; the order only spreads a payment over the chosen
ones. One function plans it (services/supplier_payment_plan.py) -- the screen
shows its answer, and the voucher records it: the cash through
attribute_cash_to_invoice, the gold through attribute_gold_across_invoices,
both at approval.

Run:
    python -m pytest tests/test_supplier_payment_plan.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (Invoice, InvoiceGoldObligation, InvoicePayment, Supplier, Voucher,
                    VoucherInvoiceGoldAttribution, db)
from tests.voucher_world import auto_post, payload, vworld  # noqa: F401 (fixture)


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
    from models import PaymentMethod
    if PaymentMethod.query.filter_by(payment_type='cash').first() is None:
        db.session.add(PaymentMethod(payment_type='cash', name='نقدي', commission_rate=0.0, is_active=True))
        db.session.flush()


def _purchase(supplier_id, day, *, wages=0.0, gold21=0.0):
    """A posted purchase of *day* October owing *wages* in cash and *gold21* g of 21k."""
    inv = Invoice(invoice_type_id=800000 + uuid.uuid4().int % 99999, invoice_type='شراء', gold_type='new',
                  supplier_id=supplier_id, date=datetime(2026, 9, day), total=10000.0,
                  gold_subtotal=10000.0 - wages, wage_subtotal=wages, status='unpaid', amount_paid=0.0,
                  is_posted=True)
    db.session.add(inv)
    db.session.flush()
    if gold21:
        db.session.add(InvoiceGoldObligation(invoice_id=inv.id, karat=21.0, weight=gold21))
        db.session.flush()
    return inv


def _plan(headers, supplier_id, invoice_ids, *, cash=0.0, gold=()):
    resp = flask_app.test_client().post(
        f'/api/suppliers/{supplier_id}/payment-plan', headers=headers,
        json={'invoice_ids': invoice_ids, 'cash': cash,
              'gold': [{'karat': k, 'weight': w} for k, w in gold]})
    return resp


def _pay(headers, w, shape, amount, invoice_ids):
    body = {**payload(w, shape, amount), 'invoice_ids': invoice_ids}
    resp = flask_app.test_client().post('/api/vouchers', headers=headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return resp.get_json()['id']


def _cash_paid(voucher_id):
    db.session.expire_all()
    return {p.invoice_id: round(p.amount, 2)
            for p in InvoicePayment.query.filter_by(source_voucher_id=voucher_id).all()}


def _gold_paid(voucher_id):
    db.session.expire_all()
    rows = VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher_id).all()
    out = {}
    for r in rows:
        out[r.invoice_id] = round(out.get(r.invoice_id, 0.0) + float(r.weight_main_karat), 2)
    return out


# ── the plan ────────────────────────────────────────────────────────────────

def test_cash_fills_the_chosen_invoices_oldest_first(auth_headers, vworld):
    s = vworld['supplier']
    a, b, c = _purchase(s, 1, wages=700), _purchase(s, 2, wages=800), _purchase(s, 3, wages=900)

    resp = _plan(auth_headers, s, [c.id, a.id], cash=1000.0)

    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    plan = resp.get_json()
    assert [(x['invoice_id'], x['amount']) for x in plan['cash']] == [(a.id, 700.0), (c.id, 300.0)]
    assert plan['cash_on_account'] == 0.0
    assert b.id not in [x['invoice_id'] for x in plan['cash']]


def test_what_the_chosen_invoices_do_not_owe_stays_on_account(auth_headers, vworld):
    s = vworld['supplier']
    a = _purchase(s, 1, wages=700)

    plan = _plan(auth_headers, s, [a.id], cash=1000.0).get_json()

    assert [(x['invoice_id'], x['amount']) for x in plan['cash']] == [(a.id, 700.0)]
    assert plan['cash_on_account'] == 300.0


def test_gold_fills_the_chosen_invoices_oldest_first(auth_headers, vworld):
    s = vworld['supplier']
    a, b = _purchase(s, 1, gold21=10.0), _purchase(s, 2, gold21=20.0)

    plan = _plan(auth_headers, s, [b.id, a.id], gold=[(21, 25.0)]).get_json()

    assert [(x['invoice_id'], x['karat'], x['weight']) for x in plan['gold']] == [
        (a.id, 21.0, 10.0), (b.id, 21.0, 15.0)]
    assert plan['gold_on_account_main_karat'] == 0.0


def test_gold_of_another_karat_is_spread_by_its_main_karat_worth(auth_headers, vworld):
    s = vworld['supplier']
    a = _purchase(s, 1, gold21=6.0)

    plan = _plan(auth_headers, s, [a.id], gold=[(18, 14.0)]).get_json()   # 14 g 18k = 12 g 21k

    split = plan['gold'][0]
    assert split['karat'] == 18.0
    assert round(split['weight'] * 18 / 21, 2) <= 6.0
    assert round(split['weight'], 3) == 7.0
    assert plan['gold_on_account_main_karat'] == 6.0


def test_it_names_each_chosen_invoice_by_its_number_and_date(auth_headers, vworld):
    s = vworld['supplier']
    a = _purchase(s, 1, wages=700)

    plan = _plan(auth_headers, s, [a.id], cash=100.0).get_json()

    row = plan['invoices'][0]
    assert row['invoice_id'] == a.id
    assert row['invoice_number'] == db.session.get(Invoice, a.id).invoice_number
    assert row['date'].startswith('2026-09-01')


@pytest.mark.parametrize('case', ('another_supplier', 'unposted'))
def test_an_invoice_the_supplier_does_not_owe_on_is_refused(auth_headers, vworld, case):
    s = vworld['supplier']
    inv = _purchase(s, 1, wages=700)
    if case == 'another_supplier':
        other = Supplier(supplier_code=f'S-{uuid.uuid4().hex[:6]}', name='مورد آخر')
        db.session.add(other)
        db.session.flush()
        inv.supplier_id = other.id
    else:
        inv.is_posted = False
    db.session.flush()

    resp = _plan(auth_headers, s, [inv.id], cash=100.0)

    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invoice_not_payable'


# ── the voucher records it ──────────────────────────────────────────────────

def test_a_cash_payment_for_chosen_invoices_pays_them_in_order(auth_headers, vworld):
    auto_post(True)
    s = vworld['supplier']
    a, b = _purchase(s, 1, wages=700), _purchase(s, 2, wages=800)

    v = _pay(auth_headers, vworld, 'cash_payment', 1000.0, [b.id, a.id])

    assert _cash_paid(v) == {a.id: 700.0, b.id: 300.0}
    db.session.expire_all()
    assert db.session.get(Invoice, a.id).status == 'paid'
    assert db.session.get(Invoice, b.id).status == 'partially_paid'


def test_the_rest_of_the_payment_stays_on_account(auth_headers, vworld):
    auto_post(True)
    s = vworld['supplier']
    a = _purchase(s, 1, wages=700)

    v = _pay(auth_headers, vworld, 'cash_payment', 1000.0, [a.id])

    assert _cash_paid(v) == {a.id: 700.0}


def test_a_gold_payment_for_chosen_invoices_is_attributed_in_order(auth_headers, vworld):
    auto_post(True)
    s = vworld['supplier']
    a, b = _purchase(s, 1, gold21=10.0), _purchase(s, 2, gold21=20.0)

    v = _pay(auth_headers, vworld, 'gold_payment', 2500.0, [a.id, b.id])   # 25 g 21k

    assert _gold_paid(v) == {a.id: 10.0, b.id: 15.0}


def test_gold_beyond_the_chosen_invoices_stays_on_account(auth_headers, vworld):
    auto_post(True)
    s = vworld['supplier']
    a = _purchase(s, 1, gold21=10.0)

    v = _pay(auth_headers, vworld, 'gold_payment', 2500.0, [a.id])

    assert _gold_paid(v) == {a.id: 10.0}


def test_chosen_invoices_owing_no_gold_take_none_of_it(auth_headers, vworld):
    auto_post(True)
    s = vworld['supplier']
    a = _purchase(s, 1, wages=700)

    v = _pay(auth_headers, vworld, 'gold_payment', 2500.0, [a.id])

    assert _gold_paid(v) == {}
    assert db.session.get(Voucher, v).status == 'approved'


def test_a_pending_voucher_records_it_when_approved(auth_headers, vworld):
    auto_post(False)
    s = vworld['supplier']
    a, b = _purchase(s, 1, wages=700), _purchase(s, 2, wages=800)

    v = _pay(auth_headers, vworld, 'cash_payment', 1000.0, [a.id, b.id])
    assert _cash_paid(v) == {}

    resp = flask_app.test_client().post(f'/api/vouchers/{v}/approve', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _cash_paid(v) == {a.id: 700.0, b.id: 300.0}


def test_without_chosen_invoices_nothing_is_attributed(auth_headers, vworld):
    auto_post(True)
    s = vworld['supplier']
    _purchase(s, 1, wages=700)

    v = _pay(auth_headers, vworld, 'cash_payment', 1000.0, [])

    assert _cash_paid(v) == {}


# ── what the employee reads back ────────────────────────────────────────────

def test_the_employees_note_reads_as_written_and_the_choice_comes_back(auth_headers, vworld):
    """The splits ride in notes; the note the employee wrote is not shown to
    them as JSON, and an edit gets back the invoices it was written for."""
    auto_post(True)
    s = vworld['supplier']
    a, b = _purchase(s, 1, wages=700), _purchase(s, 2, wages=800)
    body = {**payload(vworld, 'cash_payment', 1000.0), 'invoice_ids': [b.id, a.id],
            'notes': 'سُلّمت لمندوب المورد'}
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]

    voucher = db.session.get(Voucher, resp.get_json()['id']).to_dict()

    assert voucher['note_text'] == 'سُلّمت لمندوب المورد'
    assert voucher['invoice_ids'] == [a.id, b.id]


def test_a_plain_note_is_its_own_text(auth_headers, vworld):
    auto_post(True)
    body = {**payload(vworld, 'cash_payment', 1000.0), 'notes': 'دفعة عادية'}
    resp = flask_app.test_client().post('/api/vouchers', headers=auth_headers, json=body)

    voucher = db.session.get(Voucher, resp.get_json()['id']).to_dict()

    assert voucher['note_text'] == 'دفعة عادية'
    assert voucher['invoice_ids'] == []


def test_the_open_invoices_are_listed_by_their_numbers(auth_headers, vworld):
    """The picker shows the number the employee knows, not an id."""
    s = vworld['supplier']
    a = _purchase(s, 1, wages=700, gold21=10.0)
    number = db.session.get(Invoice, a.id).invoice_number
    client = flask_app.test_client()

    cash = client.get(f'/api/suppliers/{s}/open-cash-obligations', headers=auth_headers).get_json()
    gold = client.get(f'/api/suppliers/{s}/open-gold-obligations', headers=auth_headers).get_json()

    assert {r['invoice_id']: r['invoice_number'] for r in cash['invoices']}[a.id] == number
    assert {r['invoice_id']: r['invoice_number'] for r in gold['invoices']}[a.id] == number
