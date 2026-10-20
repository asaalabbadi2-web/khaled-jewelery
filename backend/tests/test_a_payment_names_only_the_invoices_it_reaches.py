"""A supplier payment names only the invoices it reaches (the owner, 20 Oct 2026).

«قائمة فواتير المورد في السند يجب أن تكون تحت سطور السند حتى تقرأ القيم، ولا
تقبل نسب فواتير يتجاوز المبلغ المصروف رصيدها». The plan spreads a payment over
the chosen invoices oldest first (VOUCHER-ATTR-1); when it ran out the rest took
nothing and stayed named on the voucher -- a payment of 500 read as paying three
invoices of 5,000.

The law: a chosen invoice the payment does not reach is refused,
`invoice_gets_nothing`, on create and on edit. The plan says which it does not
reach (`unreached`), so the screen locks them as the amount is typed.

Run:
    python -m pytest tests/test_a_payment_names_only_the_invoices_it_reaches.py -v
"""
import pytest

from app import app as flask_app
from models import Voucher, db
from tests.test_supplier_payment_plan import _plan, _purchase, app, cash_method, rollback_after_each  # noqa: F401
from tests.voucher_world import auto_post, payload, vworld  # noqa: F401 (fixture)


def _post(headers, w, amount, invoice_ids):
    return flask_app.test_client().post('/api/vouchers', headers=headers,
                                        json={**payload(w, 'cash_payment', amount), 'invoice_ids': invoice_ids})


def test_a_payment_naming_an_invoice_it_does_not_reach_is_refused(auth_headers, vworld):
    auto_post(True)
    a, b = _purchase(vworld['supplier'], 1, wages=700), _purchase(vworld['supplier'], 2, wages=800)
    before = Voucher.query.count()
    resp = _post(auth_headers, vworld, 500.0, [a.id, b.id])
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invoice_gets_nothing'
    assert resp.get_json()['invoice_ids'] == [b.id]
    assert Voucher.query.count() == before


@pytest.mark.parametrize('amount, chosen', [(500.0, 'a'), (1000.0, 'ab'), (1500.0, 'ab'), (2000.0, 'ab')])
def test_a_payment_naming_what_it_reaches_is_saved(auth_headers, vworld, amount, chosen):
    auto_post(True)
    invoices = {'a': _purchase(vworld['supplier'], 1, wages=700), 'b': _purchase(vworld['supplier'], 2, wages=800)}
    resp = _post(auth_headers, vworld, amount, [invoices[c].id for c in chosen])
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


def test_an_edit_naming_an_invoice_it_does_not_reach_is_refused(auth_headers, vworld):
    auto_post(False)
    a, b = _purchase(vworld['supplier'], 1, wages=700), _purchase(vworld['supplier'], 2, wages=800)
    vid = _post(auth_headers, vworld, 500.0, [a.id]).get_json()['id']
    resp = flask_app.test_client().put(f'/api/vouchers/{vid}', headers=auth_headers,
                                       json={**payload(vworld, 'cash_payment', 500.0), 'invoice_ids': [a.id, b.id]})
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invoice_gets_nothing'


def test_the_plan_says_which_it_does_not_reach(auth_headers, vworld):
    a, b = _purchase(vworld['supplier'], 1, wages=700), _purchase(vworld['supplier'], 2, wages=800)
    plan = _plan(auth_headers, vworld['supplier'], [a.id, b.id], cash=500.0).get_json()
    assert plan['unreached'] == [b.id]
    plan = _plan(auth_headers, vworld['supplier'], [a.id, b.id], cash=1000.0).get_json()
    assert plan['unreached'] == []
