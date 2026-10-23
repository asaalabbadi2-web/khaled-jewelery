"""A piece renewed with its stones as stones is sold as gold plus their value (ADR-050 ت6ج).

The owner (23 Oct 2026): a piece renewed with its stones is either «تُسجَّل
كأحجار وليس ذهبًا وتُباع ذهبًا + قيمة أحجار» or «تُسجَّل وزنًا قائمًا مع
الأحجار فتُباع كوزن ذهب»; then «اتفق مع توصياتك»: the stones' value on their
own role «مبيعات الأحجار», at no cost -- they came free with the scrap.

The second way sells as it always has. The first: a sale line says its
stones «تُباع بقيمتها» (`priced`, ADR-055's word), their weight and value.
Its gold -- the line's weight -- leaves the showroom's ledger; its stones
leave the showroom's counter, within it; its value is credited to the role,
out of the line's price, under the sale's VAT. Without the line, the sale
took the piece's standing weight of gold that never entered the ledger:
2.5 g short for sale 2974 on the 21 Oct copy.

Run:
    python -m pytest tests/test_stones_sold_by_their_value.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import AccountingMapping, Invoice, SafeBox, SafeBoxTransaction, Settings, db
from tests.test_gold_sold_at_its_cost import _cash, _from, _lines, _map, world  # noqa: F401 (fixture)

ROLE = 'stones_sales'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


@pytest.fixture
def showroom(world):
    """The safe a new-gold sale leaves -- the settings' sale safe -- is the
    showroom's, whatever another test left there."""
    _from(None)
    safe = SafeBox.query.filter_by(account_id=world['showroom'].id).first()
    Settings.query.first().sale_gold_safe_box_id = safe.id
    db.session.flush()
    return safe


def _counter(safe, grams):
    db.session.add(SafeBoxTransaction(safe_box_id=safe.id, ref_type='voucher', ref_id=0, direction='in',
                                      stones_weight=grams, stones_21k=grams, created_by='t'))
    db.session.flush()


def _sale(headers, w, *, stones=2.5, value=500.0, kind='priced', price=7000.0):
    item = {'name': 'طقم', 'karat': 21, 'weight': 14.4, 'price': price, 'net': price, 'quantity': 1,
            'wage': 0, 'selling_price': price, 'stones_weight': stones, 'stones_kind': kind,
            'stones_value': value}
    return flask_app.test_client().post('/api/invoices', headers=headers, json={
        'customer_id': w['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'employee_id': w['holder'].id, 'date': datetime(2026, 10, 21, 12).isoformat(),
        'total': price, 'total_weight': 14.4, 'total_tax': 0.0, 'total_cost': 1.0, 'amount_paid': 0.0,
        'payments': [], 'items': [item]})


def _stones_out(safe, invoice_id):
    return sum(r.stones_weight or 0.0 for r in SafeBoxTransaction.query.filter_by(
        safe_box_id=safe.id, ref_id=invoice_id, direction='out'))


def test_the_gold_leaves_the_ledger_the_stones_the_counter_their_value_its_role(auth_headers, world, showroom):
    role = _map(ROLE, '41')
    _counter(showroom, 3.0)
    resp = _sale(auth_headers, world)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    invoice_id = resp.get_json()['id']
    lines = _lines(invoice_id)

    assert _cash(lines, role.id) == pytest.approx(-500.0)
    sales = [l for l in lines if (l.description or '').endswith('إيراد مبيعات')]
    assert sum(float(l.cash_credit or 0) for l in sales) == pytest.approx(6500.0)
    gold_out = sum(float(l.credit_21k or 0) for l in lines if l.account_id == world['showroom'].id)
    assert gold_out == pytest.approx(14.4), 'the gold alone, not the standing 16.9'
    assert _stones_out(showroom, invoice_id) == pytest.approx(2.5)


def test_more_stones_than_the_showroom_counts_is_refused(auth_headers, world, showroom):
    _map(ROLE, '41')
    _counter(showroom, 1.0)
    before = Invoice.query.count()
    resp = _sale(auth_headers, world)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    body = resp.get_json()
    assert body['error'] == 'insufficient_stones_21k'
    assert body['available'] == pytest.approx(1.0)
    assert Invoice.query.count() == before


def test_the_role_unmapped_is_refused_saying_where(auth_headers, world, showroom):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    _counter(showroom, 3.0)
    resp = _sale(auth_headers, world)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']


@pytest.mark.parametrize('value,code', [(0.0, 'priced_stones_need_value'), (7000.0, 'stones_value_above_line')])
def test_a_value_missing_or_the_whole_line_is_refused(auth_headers, world, showroom, value, code):
    _map(ROLE, '41')
    _counter(showroom, 3.0)
    resp = _sale(auth_headers, world, value=value)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == code


def test_stones_counted_as_gold_sell_as_they_always_have(auth_headers, world, showroom):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    resp = _sale(auth_headers, world, kind='as_gold', value=0.0)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    invoice_id = resp.get_json()['id']
    assert _stones_out(showroom, invoice_id) == 0.0


def test_its_return_is_refused_until_built(auth_headers, world, showroom):
    _map(ROLE, '41')
    _counter(showroom, 3.0)
    sold = _sale(auth_headers, world).get_json()
    resp = flask_app.test_client().post(f'/api/invoices/{sold["id"]}/reverse', headers=auth_headers,
                                        json={'reason': 'عيب', 'payments': []})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'priced_stones_return_not_built'
