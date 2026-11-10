"""A sale's and a scrap purchase's every line has its price (the owner, 10 Nov 2026).

The screens filled a sale line at its cost until the asked amount was spread
over the lines -- with Enter, which an iPhone's number pad has none of -- and
sales were saved at cost. The screens now leave a line without its price
until it is written or spread; the server holds it so: a line priced at
nothing, or below, is refused, saying the line -- before anything is saved,
whatever screen or version sent it. No sale (2,999 lines) and no scrap
purchase (1,153) on the 10 Nov copy has one. The supplier's purchase and the
returns are not held here (their lines carry no price: 312 of 312).

Run:
    python -m pytest tests/test_invoice_line_is_priced.py -v
"""
import pytest

from models import Invoice
from tests.test_invoice_amounts_are_not_negative import (  # noqa: F401 -- the module's fixtures
    _refused, _sale, _save, _scrap, app, rollback_after_each,
)
from tests.retraction_world import world  # noqa: F401 -- the fixture


@pytest.mark.parametrize('price', [0.0, -5.0, None])
def test_a_sale_line_without_its_price_is_refused(auth_headers, world, price):
    line = {'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'net': 0.0, 'quantity': 1, 'wage': 0}
    if price is not None:
        line['price'] = price
    before = Invoice.query.count()
    resp = _save(auth_headers, _sale(world, items=[line], total=0.0))
    _refused(resp, 'line_unpriced')
    assert 'السطر 1' in resp.get_json()['message']
    assert Invoice.query.count() == before, 'nothing saved'


def test_a_scrap_purchase_line_without_its_price_is_refused(auth_headers, world):
    line = {'name': 'كسر', 'karat': 18, 'weight': 0.5, 'standing_weight': 0.5, 'stones_weight': 0.0,
            'price': 0.0, 'net': 0.0, 'quantity': 1}
    _refused(_save(auth_headers, _scrap(world, items=[line], payments=[], amount_paid=0.0, total=0.0)),
             'line_unpriced')


def test_the_second_line_is_named(auth_headers, world):
    priced = {'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0, 'quantity': 1,
              'wage': 0}
    resp = _save(auth_headers, _sale(world, items=[priced, dict(priced, price=0.0, net=0.0)]))
    _refused(resp, 'line_unpriced')
    assert 'السطر 2' in resp.get_json()['message']


def test_priced_lines_are_taken(auth_headers, world):
    for payload in (_sale(world), _scrap(world)):
        resp = _save(auth_headers, payload)
        assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
