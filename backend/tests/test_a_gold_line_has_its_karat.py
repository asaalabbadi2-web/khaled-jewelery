"""A gold line has its own karat -- one with none is refused (the owner, 20 Oct 2026).

Beside the main karat (test_main_karat_is_the_settings), the server guessed a
line's own karat: an invoice line or karat line with none -- or one that is no
karat, 20 -- was posted to the safes and the supplier's gold obligations as 21
(posting_routes, gold_allocation_service), a melting with no karat melted 21,
an item created inline with none was 21. The 17 Oct production copy holds no
such line (0 of 4,032 invoice lines, 40 karat lines, 978 voucher gold lines):
the guesses only ever hid a fault.

The law: pricing.karat_service.line_karat() reads a line's karat, one of
18/21/22/24, or raises LineKaratMissing -- the posting rolls back, the
request is refused `line_karat_missing` (or the route's own invalid_karat).

Run:
    python -m pytest tests/test_a_gold_line_has_its_karat.py -v
"""
from types import SimpleNamespace

import pytest

from app import app as flask_app
from pricing.karat_service import LineKaratMissing, line_karat
from tests.test_melting_is_one_voucher import _gold_safe, _ledger, _post, _vouchers_from


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.mark.parametrize('value, karat', [(21, 21), ('18', 18), (22.0, 22), ('24.0', 24)])
def test_a_karat_is_read(value, karat):
    assert line_karat(value) == karat


@pytest.mark.parametrize('value', [None, '', 0, 20, 'x'])
def test_no_karat_is_refused(value):
    with pytest.raises(LineKaratMissing):
        line_karat(value)


def test_an_invoice_line_with_no_karat_is_not_posted_as_21():
    from posting_routes import invoice_gold_plan
    invoice = SimpleNamespace(id=1, invoice_type='شراء من عميل', gold_type='scrap', items=[],
                              karat_lines=[SimpleNamespace(karat=None, weight_grams=5.0)])
    with pytest.raises(LineKaratMissing):
        invoice_gold_plan(invoice, posted=False)


def test_a_melting_with_no_karat_is_refused(auth_headers):
    source, target = _gold_safe('معروض'), _gold_safe('كسر')
    _ledger(source, 21, 10.0)
    resp = _post(auth_headers, {'operation_type': 'melting', 'from_safe_box_id': source.id,
                                'to_safe_box_id': target.id, 'gold_weight': 2.0, 'stones_weight': 0.0})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'invalid_karat'
    assert _vouchers_from(source) == []
