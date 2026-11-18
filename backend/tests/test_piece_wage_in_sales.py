"""A piece's wage reaches the sale line (the owner, 18 Nov 2026).

«لم يتم تطبيق أجور الفاتورة على القطعة في فاتورة البيع، ظهرت 0»: the sales
screen reads the items' list, and a piece's wage is never kept on it -- it
is its receipt line's (ADR-087 §6) -- so the list sent nothing. The law:
the list sends a piece its wage per gram from its source, and whether it is
known; nothing while its invoice is not completed.

Run:
    python -m pytest tests/test_piece_wage_in_sales.py -v
"""
from flask import g

from services.pieces import register_piece
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_station import _complete
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _listed(auth_headers, piece_id):
    from app import app as flask_app
    g.pop('current_user', None)
    rows = flask_app.test_client().get('/api/items', headers=auth_headers).get_json()
    return next(r for r in rows if r['id'] == piece_id)


def test_the_items_list_sends_a_piece_its_invoices_wage_per_gram(auth_headers, world, roles, showroom,
                                                                 bangles_by_the_piece):
    invoice, line = _received(auth_headers, world, 30.0)
    bangles_by_the_piece(line)
    piece = register_piece(line, weight=10.0, by='t', now=NOW)
    before = _listed(auth_headers, piece.id)
    assert (before['is_piece'], before['wage_known'], before['wage']) == (True, False, None), 'its invoice not yet'
    _complete(auth_headers, world, invoice, line, 15.0)
    after = _listed(auth_headers, piece.id)
    assert (after['wage_known'], after['wage'], after['manufacturing_wage_per_gram']) == (True, 15.0, 15.0)


def test_a_piece_out_of_the_stock_is_not_offered_for_sale(auth_headers, world, roles, showroom, bangles_by_the_piece):
    """The owner, 18 Nov 2026: a sold piece was offered by the sales screen and
    refused only at the save. Asked for what is in the stock, the list leaves
    it out; asked for everything, it is there."""
    from app import app as flask_app
    from tests.test_pieces_list import _out
    invoice, line = _received(auth_headers, world, 30.0)
    bangles_by_the_piece(line)
    kept = register_piece(line, weight=10.0, by='t', now=NOW)
    sold = register_piece(line, weight=8.0, by='t', now=NOW)
    _out(sold, showroom, invoice, invoice_type='بيع', when=NOW)

    def ids(query=''):
        g.pop('current_user', None)
        return {r['id'] for r in flask_app.test_client().get(f'/api/items{query}', headers=auth_headers).get_json()}
    offered = ids('?in_stock_only=true')
    assert kept.id in offered and sold.id not in offered
    assert {kept.id, sold.id} <= ids(), 'asked for everything, the sold one is listed'
