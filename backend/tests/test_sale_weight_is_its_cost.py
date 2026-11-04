"""A sale's grams go to the cost of sales by weight, not to the customer (CUSTGOLD-001).

The constitution's CUSTGOLD-001: 19,495 g sat on the customers' weight twins
(712…) on the 2 Nov copy -- the weight of every gold sold since January, each
sale debiting its customer's twin for the grams it took out of the stock. No
customer holds the shop's gold: the owner (5 Nov 2026) «تصحيح الكاتب ونقل
الرصيد». From this release a sale debits «تكلفة مبيعات الذهب وزني» (the role
gold_cost_of_sales_weight, 7521 on production) and its return credits it; a
sale's correction puts its difference there too. Unmapped, the sale is
refused -- never back on the customer.

The gold's cost replay (ADR-042) reads a sale by where its grams went: to
the cost of sales by weight it is a sale, as to a customer was -- not a
purchase returned. The balance already there moves by its tool
(tests/test_customer_gold_to_cost_of_sales.py).

Run:
    python -m pytest tests/test_sale_weight_is_its_cost.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from accounting.chart_tree import role_account_id
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
from app import app as flask_app
from models import Account, AccountingMapping, JournalEntryLine, SafeBox, db
from services.gold_cost import replay
from tests.test_gold_cost import _account, _child, _entry
from tests.test_gold_sold_at_its_cost import _from, _lines, _sale, _square, world  # noqa: F401 (fixture)

ROLE = 'gold_cost_of_sales_weight'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _sold_weight():
    return get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, ROLE)


def _grams(lines, account_id):
    return round(sum(float(l.debit_21k or 0) - float(l.credit_21k or 0) for l in lines if l.account_id == account_id), 3)


def test_a_sale_puts_its_grams_on_the_cost_of_sales_by_weight(auth_headers, world):
    _from(None)
    resp = _sale(auth_headers, world)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    lines = _lines(resp.get_json()['id'])
    assert _grams(lines, _sold_weight()) == pytest.approx(10.0)
    twin = db.session.get(Account, world['customer'].account_id).memo_account_id
    assert _grams(lines, twin) == 0, 'no gold on the customer'


def test_a_sale_returned_takes_them_back_off_it(auth_headers, world):
    _from(None)
    sold = _sale(auth_headers, world).get_json()
    resp = flask_app.test_client().post(f'/api/invoices/{sold["id"]}/reverse', headers=auth_headers,
                                        json={'reason': 'عيب', 'payments': []})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    lines = _lines(resp.get_json()['id'])
    assert _grams(lines, _sold_weight()) == pytest.approx(-10.0)
    twin = db.session.get(Account, world['customer'].account_id).memo_account_id
    assert _grams(lines, twin) == 0


def test_with_the_role_unmapped_a_sale_is_refused_not_put_on_the_customer(auth_headers, world):
    _from(None)
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    db.session.flush()
    resp = _sale(auth_headers, world)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert ROLE in resp.get_json()['detail']


def test_the_replay_reads_grams_sold_onto_it_as_a_sale_and_back_as_its_return():
    """In 2032, alone: 100 g bought at 500; 10 g sold onto the cost of sales
    by weight, with no riyal cost written (2026's sales), then returned. The
    replay sells them at the average and brings them back: not a purchase
    returned."""
    b = {'showroom': _child(_account('7139'), 'معروض 2032 SW'),
         'twin': _child(_account('7512'), 'مشتريات وزني 2032 SW'), 'cash': _child(_account('1100'), 'صندوق 2032 SW')}
    db.session.add(SafeBox(name=f'معروض 2032 {uuid.uuid4().hex[:4]}', safe_type='gold', account_id=b['showroom'].id,
                           stock_location='showroom', is_active=True))
    db.session.flush()
    worked_value = db.session.get(Account, role_account_id('gold_inventory_new'))
    sold_weight = db.session.get(Account, _sold_weight())
    _entry(1, [(b['showroom'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (worked_value, {'cash_debit': 50000}), (b['cash'], {'cash_credit': 50000})])
    _entry(2, [(b['showroom'], {'credit_21k': 10}), (sold_weight, {'debit_21k': 10})])

    r = replay(opening_price=0.0, since=date(2032, 1, 1), until=date(2032, 2, 1))
    month = r.months['2032-01']
    assert (month.sold_worked_g, month.cost_of_worked_sold) == (pytest.approx(10), pytest.approx(5000))
    assert month.purchases_g == pytest.approx(100), 'not a purchase returned'

    _entry(3, [(b['showroom'], {'debit_21k': 10}), (sold_weight, {'credit_21k': 10})])
    r = replay(opening_price=0.0, since=date(2032, 1, 1), until=date(2032, 2, 1))
    month = r.months['2032-01']
    assert month.sold_worked_g == pytest.approx(0), 'returned: nothing sold'
    assert month.purchases_g == pytest.approx(100)
