"""A piece brought back by a sale return, and its label (ADR-097, the sale
return; the owner, 23 Nov 2026: «الزبون قد يتلف البطاقة» -- «جميع الاحتمالات
وارده»). The reader decides, not a person: its tag read, its printed number,
or its label missing and printed again -- never a label not its own; and the
nightly check says a piece whose label the return did not settle.

Run:
    python -m pytest tests/test_return_tags.py -v
"""
import uuid
from datetime import datetime, timedelta

import pytest

from models import Item, PieceReturnTag, PieceScan, PieceScanRead, SafeBox, db
from services.books_invariants import RETURNED_PIECE_UNLABELED, check_returned_pieces_unlabeled
from services.pieces import epc_of, mount_tag, piece_held, replace_tag
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_sale import _piece
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_return_takes_its_piece import _cash, _post, _return, _sell, as_production  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


@pytest.fixture
def sold(auth_headers, as_production, world, roles, showroom, bangles_by_the_piece):
    """A piece with its label, sold."""
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    mount_tag(piece, value=epc_of(piece.item_code, 1), by='t', now=datetime.now() - timedelta(days=1))
    sale = _sell(auth_headers, piece, _cash())
    return piece, sale


def _back(headers, piece, sale, tag):
    payload = _return(sale, weight=piece.weight, price=9500.0)
    if tag is not None:
        payload['items'][0]['tag'] = tag
    return _post(headers, payload)


def _said(piece):
    return PieceReturnTag.query.filter_by(item_id=piece.id).one_or_none()


def _unlabeled(piece):
    return [f for f in check_returned_pieces_unlabeled() if f.detail['item_id'] == piece.id]


def test_a_piece_comes_back_only_with_its_label_said(auth_headers, sold):
    piece, sale = sold
    resp = _back(auth_headers, piece, sale, None)
    assert resp.status_code == 400 and resp.get_json()['error'] == 'return_tag_required', resp.get_json()
    assert piece.item_code in resp.get_json()['message']
    assert piece_held(piece.id) == 0.0 and _said(piece) is None, 'nothing written'


def test_its_own_tag_read_brings_it_back_with_its_label(auth_headers, sold):
    piece, sale = sold
    resp = _back(auth_headers, piece, sale, {'value': epc_of(piece.item_code, 1).lower()})
    assert resp.status_code == 201, resp.get_json()
    said = _said(piece)
    assert (said.kind, said.value, said.invoice_id) == ('read', epc_of(piece.item_code, 1), resp.get_json()['id'])
    assert piece_held(piece.id) == piece.weight
    assert _unlabeled(piece) == [], 'its label is with it'


def test_its_printed_number_alone_is_said_until_a_count_reads_its_tag(auth_headers, sold):
    piece, sale = sold
    resp = _back(auth_headers, piece, sale, {'value': piece.item_code})
    assert resp.status_code == 201, resp.get_json()
    assert _said(piece).kind == 'printed'
    found = _unlabeled(piece)
    assert found and found[0].kind == RETURNED_PIECE_UNLABELED and found[0].detail['kind'] == 'printed'
    scan = PieceScan(safe_box_id=SafeBox.query.filter(SafeBox.stock_location.isnot(None)).first().id, kind='check',
                     status='finished', started_at=datetime.now() + timedelta(minutes=1), places={}, presses=1)
    db.session.add(scan)
    db.session.flush()
    db.session.add(PieceScanRead(scan_id=scan.id, value=epc_of(piece.item_code, 1), first_press=1, first_ms=0,
                                 item_id=piece.id, verdict='found'))
    db.session.flush()
    assert _unlabeled(piece) == [], 'a count read its tag: settled'


def test_its_label_missing_is_said_until_a_new_one_is_adopted(auth_headers, sold):
    piece, sale = sold
    resp = _back(auth_headers, piece, sale, {'missing': True})
    assert resp.status_code == 201, resp.get_json()
    assert (_said(piece).kind, _said(piece).value) == ('missing', None)
    assert [f.detail['kind'] for f in _unlabeled(piece)] == ['missing']
    replace_tag(piece, reason='مرتجع بيع — البطاقة مفقودة', value=epc_of(piece.item_code, 2), by='t',
                now=datetime.now() + timedelta(minutes=1))
    assert _unlabeled(piece) == [], 'a new label adopted: settled'


def test_a_label_not_its_own_is_never_taken(auth_headers, sold, world, showroom, bangles_by_the_piece):
    piece, sale = sold
    other = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    mount_tag(other, value=epc_of(other.item_code, 1), by='t', now=NOW)
    for tag, code in (({'value': epc_of(other.item_code, 1)}, 'return_tag_other_piece'),
                      ({'value': other.item_code}, 'return_tag_other_piece'),
                      ({'value': '4B4A0001' + '9' * 16}, 'return_tag_unknown'),
                      ({'value': 'E2801170000002' + '0' * 10}, 'return_tag_unknown')):
        resp = _back(auth_headers, piece, sale, tag)
        assert resp.status_code == 400 and resp.get_json()['error'] == code, (tag, resp.get_json())
    replace_tag(piece, reason='تلفت', value=epc_of(piece.item_code, 2), by='t', now=NOW)
    resp = _back(auth_headers, piece, sale, {'value': epc_of(piece.item_code, 1)})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'return_tag_not_active', resp.get_json()
    assert piece_held(piece.id) == 0.0 and _said(piece) is None


def test_a_line_by_weight_says_no_label(auth_headers, as_production, world, roles, showroom):
    from models import Customer
    pm = _cash()
    resp = _post(auth_headers, {
        'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'total': 2000.0, 'total_weight': 4.0, 'total_tax': 0.0,
        'amount_paid': 2000.0, 'payments': [{'payment_method_id': pm.id, 'amount': 2000.0}],
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 4.0, 'wage': 20.0, 'quantity': 1, 'price': 2000.0,
                   'net': 2000.0, 'selling_price': 2000.0}]})
    assert resp.status_code == 201, resp.get_json()
    back = _post(auth_headers, _return(resp.get_json(), weight=4.0, price=2000.0))
    assert back.status_code == 201, back.get_json()
    assert PieceReturnTag.query.filter_by(invoice_id=back.get_json()['id']).count() == 0
