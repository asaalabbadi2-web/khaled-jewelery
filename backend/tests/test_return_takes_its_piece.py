"""A sold line comes back as it was sold (the owner, 18 Nov 2026).

«القطعة ترجع كاملة وأجرتها من بيعها». Probed on a copy of the 17 Nov
production: the return screen sent no piece and a wage of 0, so KJ-000007
came back as 13 g of its category -- the piece still sold, never offered
again, «بلا موديل» −13 g in the sales analysis -- and its 195.00 of wages
stayed on the expense; every customer return line from 398706068 gave back
no wages (13 and 15 Nov carried them). Now a sale return's line takes its
sale line's piece and wage, whatever the screen sends, and a piece comes
back whole.

Run:
    python -m pytest tests/test_return_takes_its_piece.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from models import (Account, Customer, InvoiceItem, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox,
                    StockLineAllocation, db)
from services.pieces import piece_held
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_sale import _line, _piece
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_stock_count import roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


@pytest.fixture
def as_production(world):
    """1300 carries riyals alone, its grams on its twin -- the display (production: 1300 cash, 71300 gold)."""
    stock = Account.query.filter_by(account_number='1300').one()
    stock.transaction_type, stock.tracks_weight = 'cash', False
    db.session.get(Account, stock.memo_account_id).transaction_type = 'gold'
    db.session.flush()


def _post(headers, payload):
    from app import app as flask_app
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def _cash():
    box = SafeBox(name=f'خزينة R {uuid.uuid4().hex[:6]}', safe_type='cash', account_id=Account.query.get(15).id,
                  is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(payment_type='cash', name=f'نقداً R {uuid.uuid4().hex[:6]}', commission_rate=0.0,
                       is_active=True, default_safe_box_id=box.id)
    db.session.add(pm)
    db.session.flush()
    return pm


def _sell(headers, piece, pm, price=9500.0):
    resp = _post(headers, {
        'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'total': price, 'total_weight': piece.weight, 'total_tax': 0.0,
        'amount_paid': price, 'payments': [{'payment_method_id': pm.id, 'amount': price}],
        'items': [_line(piece, name='بنجرة', quantity=1, price=price, net=price, selling_price=price)]})
    assert resp.status_code == 201, resp.get_json()
    return resp.get_json()


def _piece_moves(invoice_id):
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id,
                                                         is_deleted=False)]
    return [(a.item_id, round(a.grams, 3)) for a in StockLineAllocation.query.join(JournalEntryLine)
            .filter(JournalEntryLine.journal_entry_id.in_(entries or [-1]))]


def test_the_sale_takes_the_piece_out(auth_headers, as_production, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    sale = _sell(auth_headers, piece, _cash())
    assert _piece_moves(sale['id']) == [(piece.id, -piece.weight)]
    assert piece_held(piece.id) == 0.0



def _return(sale, *, weight, price, item_id=None, wage=0.0):
    """As the return screen sends it: the line it gives back, no piece, a wage of 0."""
    line = sale['items'][0]
    return {
        'customer_id': sale['customer_id'], 'invoice_type': 'مرتجع بيع', 'original_invoice_id': sale['id'],
        'gold_type': 'new', 'date': datetime.now().isoformat(), 'return_reason': 'عيب',
        'total': price, 'total_weight': weight, 'total_tax': 0.0, 'total_cost': price, 'amount_paid': 0.0,
        'payments': [],
        'items': [{'item_id': item_id, 'original_invoice_item_id': line['id'], 'name': line['name'], 'karat': 21,
                   'weight': weight, 'wage': wage, 'quantity': 1, 'cost': price, 'net': price, 'tax': 0.0,
                   'tax_amount': 0.0, 'price': price}]}


def _wages(invoice_id):
    """(onto the wages' stock, off the wages' expense) the invoice's entry wrote."""
    from accounting.wages import manufacturing_wage_expense_account_id, manufacturing_wage_inventory_account_id
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id,
                                                         is_deleted=False)]

    def net(account_id):
        return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in JournalEntryLine.query.filter(
            JournalEntryLine.journal_entry_id.in_(entries or [-1]), JournalEntryLine.account_id == account_id)), 2)
    return net(manufacturing_wage_inventory_account_id()), net(manufacturing_wage_expense_account_id())


def test_a_piece_comes_back_with_its_wages_whatever_the_screen_sent(auth_headers, as_production, world, roles,
                                                                    showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    sale = _sell(auth_headers, piece, _cash())
    released = _wages(sale['id'])
    assert released == (-215.55, 215.55), 'the sale released 15.00 x 14.37'
    payload = _return(sale, weight=piece.weight, price=9500.0)
    payload['items'][0]['tag'] = {'missing': True}      # its label said (ADR-097, tests/test_return_tags.py)
    resp = _post(auth_headers, payload)
    assert resp.status_code == 201, resp.get_json()
    ret = resp.get_json()
    assert _piece_moves(ret['id']) == [(piece.id, piece.weight)], 'the piece came back, not grams of its category'
    assert piece_held(piece.id) == piece.weight
    assert _wages(ret['id']) == (215.55, -215.55), 'its wages back onto their stock'
    assert InvoiceItem.query.filter_by(invoice_id=ret['id']).one().item_id == piece.id


def test_a_piece_comes_back_whole(auth_headers, as_production, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    sale = _sell(auth_headers, piece, _cash())
    resp = _post(auth_headers, _return(sale, weight=6.0, price=4000.0, item_id=piece.id, wage=15.0))
    assert resp.status_code == 400 and resp.get_json()['error'] == 'piece_returned_whole', resp.get_json()
    assert piece_held(piece.id) == 0.0, 'nothing written'


def test_a_weighed_line_gives_back_its_wage_in_the_grams_returned(auth_headers, as_production, world, roles, showroom,
                                                                  bangles_by_the_piece):
    _piece(auth_headers, world, showroom, bangles_by_the_piece)   # 20 g received: 5.63 g left unpieced
    pm = _cash()
    resp = _post(auth_headers, {
        'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'total': 2000.0, 'total_weight': 4.0, 'total_tax': 0.0,
        'amount_paid': 2000.0, 'payments': [{'payment_method_id': pm.id, 'amount': 2000.0}],
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 4.0, 'wage': 20.0, 'quantity': 1, 'price': 2000.0,
                   'net': 2000.0, 'selling_price': 2000.0}]})
    assert resp.status_code == 201, resp.get_json()
    sale = resp.get_json()
    assert _wages(sale['id']) == (-80.0, 80.0)
    ret = _post(auth_headers, _return(sale, weight=1.5, price=750.0))
    assert ret.status_code == 201, ret.get_json()
    assert _wages(ret.get_json()['id']) == (30.0, -30.0), '20.00 x 1.5 g -- the screen sent 0'


def test_the_lines_to_return_name_the_piece(auth_headers, as_production, world, roles, showroom,
                                            bangles_by_the_piece):
    from app import app as flask_app
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    sale = _sell(auth_headers, piece, _cash())
    g.pop('current_user', None)
    line = flask_app.test_client().get(f"/api/invoices/{sale['id']}/return-lines",
                                       headers=auth_headers).get_json()['lines'][0]
    assert (line['item_id'], line['item_code'], line['is_piece']) == (piece.id, piece.item_code, True)
