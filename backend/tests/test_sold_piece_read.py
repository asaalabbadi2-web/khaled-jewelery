"""A piece sold, then read (the owner, 21 Nov 2026: «لم نجرب هل يستهلك البيع
القطع وماذا يكتب القارئ إذا وجد قطعة مباعة»).

The sale is the real one -- posted through POST /api/invoices, not an entry
written by hand. It takes the piece out of stock; a reader that reads its
tag afterwards -- in «جرد بالمسح» or «تحقّق من بطاقة» -- says it is not in
stock and how it left: «ليست في المخزون — بيعت <its day>». Both say it in
the same words, from one function.

Run:
    python -m pytest tests/test_sold_piece_read.py -v
"""
from datetime import datetime

from flask import g

from services.piece_scan import OUT, scan_view, start_scan, take_reads
from services.pieces import epc_of, mount_tag, piece_held
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_sale import _piece
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_return_takes_its_piece import _cash, _sell, as_production  # noqa: F401
from tests.test_stock_count import roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _get(headers, path):
    from app import app as flask_app
    g.pop('current_user', None)
    return flask_app.test_client().get(path, headers=headers)


def _sold_tagged(auth_headers, world, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    tag = mount_tag(piece, by='t', now=datetime.now())
    _sell(auth_headers, piece, _cash())
    return piece, tag.value


def test_the_sale_takes_it_out_and_the_scan_says_it_was_sold(auth_headers, as_production, world, roles, showroom,
                                                              bangles_by_the_piece):
    piece, value = _sold_tagged(auth_headers, world, showroom, bangles_by_the_piece)
    assert piece_held(piece.id) == 0.0
    scan = start_scan(safe_box_id=showroom.id, kind='check', by='t', now=datetime.now())
    take_reads(scan.id, batch_key='k1', events=[{'kind': 'read', 'value': value, 'press': 1, 'ms': 100}],
               now=datetime.now())
    [read] = scan_view(scan)['reads']
    assert read['verdict'] == OUT
    assert read['words'] == f'{piece.item_code} — ليست في المخزون — بيعت {datetime.now():%Y-%m-%d}'


def test_the_tag_check_says_it_was_sold_in_the_same_words(auth_headers, as_production, world, roles, showroom,
                                                           bangles_by_the_piece):
    piece, value = _sold_tagged(auth_headers, world, showroom, bangles_by_the_piece)
    words = f'ليست في المخزون — بيعت {datetime.now():%Y-%m-%d}'
    by_tag = _get(auth_headers, f'/api/pieces/by-tag/{value}')
    assert by_tag.status_code == 200, by_tag.get_json()
    body = by_tag.get_json()
    assert body['piece']['in_stock'] is False and body['location'] is None
    assert body['out'] == {'state': 'sold', 'date': f'{datetime.now():%Y-%m-%d}', 'words': words}
    by_code = _get(auth_headers, f'/api/pieces/lookup?code={piece.item_code}').get_json()
    assert by_code['out'] == body['out'], 'its printed code says the same'


def test_a_piece_in_stock_has_no_exit(auth_headers, as_production, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    tag = mount_tag(piece, by='t', now=datetime.now())
    body = _get(auth_headers, f'/api/pieces/by-tag/{tag.value}').get_json()
    assert body['piece']['in_stock'] is True and body['out'] is None
    assert epc_of(piece.item_code) == tag.value
