"""A supplier's purchase line is a category, never an item (the owner, 8 Nov 2026).

The purchase's lines are lots: on the 5 Nov copy 299 lines averaging 94 g
(«بناجر», 26 lines, 5,632 g). Yet the screen's quick row made each typed line
an item in the catalogue (create_inline): 19 «items» that were lots --
I-000001 «سلاسل حبل ومبروم» 139 g, I-000002 of 0 g -- in the table that will
hold the piece (ADR-085), and the transition carries their item into 2027. A
piece is registered on receiving, by its one writer; the purchase line says
its category, chosen from the list, of the line's karat (ADR-045: a category's
karat is fixed). On the copy 4 lines had none and 1 a category of another
karat («سبايك الديوان» 21k as «سبايك ذهب عيار 24»).

Run:
    python -m pytest tests/test_purchase_line_is_a_category.py -v
"""
import uuid

import pytest

from models import Category, db
from services.purchase_lines import PurchaseLineRefused, refuse_purchase_lines


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _category(karat='21', **kw):
    c = Category(name=f'تصنيف {uuid.uuid4().hex[:6]}', karat=karat, **{'is_active': True, **kw})
    db.session.add(c)
    db.session.flush()
    return c


def _line(category=None, karat=21, **kw):
    return {'name': 'بناجر', 'karat': karat, 'weight': 216.4, 'category_id': category.id if category else None, **kw}


def _refusal(items, invoice_type='شراء', gold_type='new'):
    try:
        refuse_purchase_lines(invoice_type, gold_type, items)
    except PurchaseLineRefused as refused:
        return refused.code, refused.message
    return None


def test_a_line_with_its_category_of_its_karat_passes():
    assert _refusal([_line(_category())]) is None


def test_a_line_without_a_category_is_refused_saying_which():
    assert _refusal([_line(_category()), _line()]) == ('purchase_line_category_required',
                                                       'السطر 2: اختر تصنيف السطر')


@pytest.mark.parametrize('kw', [{'create_inline': True}, {'item_id': 7}])
def test_a_line_is_no_item(kw):
    code, message = _refusal([_line(_category(), **kw)])
    assert code == 'purchase_line_is_a_category'
    assert 'الاستلام' in message, 'where a piece is registered'


def test_a_category_of_another_karat_is_refused():
    code, message = _refusal([_line(_category('24'), karat=21)])
    assert code == 'purchase_line_karat_mismatch'
    assert '24' in message and '21' in message


@pytest.mark.parametrize('kw', [{'is_active': False}, {'is_scrap': True}])
def test_a_stopped_or_scrap_category_is_refused(kw):
    assert _refusal([_line(_category(**kw))])[0] == 'purchase_line_category_invalid'


@pytest.mark.parametrize('invoice_type, gold_type', [('شراء', 'scrap'), ('شراء من عميل', 'scrap'),
                                                     ('مرتجع شراء (مورد)', 'new'), ('بيع', 'new')])
def test_other_invoices_are_not_its(invoice_type, gold_type):
    assert _refusal([_line()], invoice_type, gold_type) is None


def test_the_route_refuses_it(auth_headers):
    from app import app as flask_app
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'invoice_type': 'شراء', 'gold_type': 'new', 'items': [_line()]})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'purchase_line_category_required'
