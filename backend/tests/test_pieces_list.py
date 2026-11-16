"""The pieces' list: each piece with its place, its state and its receipt -- searched, filtered and paged by the server (the owner, 16 Nov 2026).

«قائمة القطع» (ADR-087): the items screen loaded every item into the device
and showed a «stock» typed by hand. A piece's place and state are the books':
  - its place is the stock safe whose lines hold its allocations;
  - in stock while they hold more than nothing; out, by the document that
    took it out -- sold (a sale), returned to the supplier, or out (any other);
  - the list is the pieces' only -- a catalogue item (I-) is not a piece;
  - the server searches (number, name, a tag read), filters (category, karat,
    place, state), sorts and pages, and says the shop's summary: pieces in
    stock and their grams, those in stock without a tag, those sold this month.

Run:
    python -m pytest tests/test_pieces_list.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import Invoice, Item, JournalEntry, JournalEntryLine, db
from services.pieces import PiecesFilterInvalid, epc_of, mount_tag, pieces_list, register_piece
from services.stock_ledger import allocate
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401

TODAY = datetime(2026, 11, 16, 12, 0)


def _out(piece, safe, receipt, *, invoice_type, when):
    """The piece taken out of *safe* by a posted entry of an invoice of *invoice_type*."""
    document = Invoice(invoice_type_id=receipt.invoice_type_id, invoice_type=invoice_type, date=when, total=0.0)
    db.session.add(document)
    db.session.flush()
    entry = JournalEntry(entry_number=f'JE-P-{uuid.uuid4().hex[:8]}', date=when, description=invoice_type,
                         entry_type='عادي', is_posted=True, is_draft=False, created_by='t',
                         reference_type='invoice', reference_id=document.id)
    db.session.add(entry)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=entry.id, account_id=safe.account_id, description=invoice_type,
                            credit_21k=piece.weight)
    db.session.add(line)
    db.session.flush()
    allocate(line, 21, piece.category_id, -piece.weight, item_id=piece.id, by='t', now=NOW)


@pytest.fixture
def three(auth_headers, world, roles, showroom, bangles_by_the_piece):
    receipt, line = _received(auth_headers, world, 20.0)
    bangles_by_the_piece(line)
    kept = register_piece(line, weight=6.5, by='t', now=NOW)
    sold = register_piece(line, weight=5.25, stones_weight=0.4, by='t', now=NOW)
    returned = register_piece(line, weight=4.0, by='t', now=NOW)
    mount_tag(kept, by='t', now=NOW)
    _out(sold, showroom, receipt, invoice_type='بيع', when=datetime(2026, 11, 10))
    _out(returned, showroom, receipt, invoice_type='مرتجع شراء (مورد)', when=datetime(2026, 10, 20))
    return {'receipt': receipt, 'line': line, 'kept': kept, 'sold': sold, 'returned': returned,
            'showroom': showroom}


def _codes(listed):
    return [p['item_code'] for p in listed['pieces']]


def test_each_piece_says_its_place_its_state_and_its_receipt(three):
    listed = pieces_list(state='all', today=TODAY)
    by = {p['item_code']: p for p in listed['pieces']}
    kept, sold, returned = (by[three[k].item_code] for k in ('kept', 'sold', 'returned'))
    assert kept['state'] == 'in_stock' and kept['location'] == {'id': three['showroom'].id,
                                                                  'name': three['showroom'].name}
    assert kept['tag'] == epc_of(three['kept'].item_code) and kept['left_at'] is None
    assert (sold['state'], sold['left_at'], sold['location']) == ('sold', '2026-11-10', None)
    assert sold['stones_weight'] == 0.4
    assert returned['state'] == 'returned_to_supplier'
    receipt = three['receipt']
    assert kept['received'] == {'kind': 'receipt', 'date': receipt.date.date().isoformat(),
                                'document': receipt.invoice_number, 'invoice_id': receipt.id,
                                'supplier_name': kept['received']['supplier_name']}
    assert kept['category_name'] and kept['karat'] == '21'


def test_in_stock_unless_asked_and_by_category_karat_and_place(three):
    assert _codes(pieces_list(today=TODAY)) == [three['kept'].item_code], 'in stock, unless asked'
    category = three['kept'].category_id
    assert _codes(pieces_list(category_id=category, today=TODAY)) == [three['kept'].item_code]
    assert _codes(pieces_list(category_id=category + 999, today=TODAY)) == []
    assert _codes(pieces_list(karat=18, today=TODAY)) == []
    assert _codes(pieces_list(safe_box_id=three['showroom'].id, today=TODAY)) == [three['kept'].item_code]
    assert _codes(pieces_list(safe_box_id=three['showroom'].id + 999, today=TODAY)) == []
    assert _codes(pieces_list(state='sold', today=TODAY)) == [three['sold'].item_code]


def test_searched_by_its_number_its_name_or_a_tag_read(three):
    kept = three['kept']
    assert _codes(pieces_list(q=kept.item_code.lower(), state='all', today=TODAY)) == [kept.item_code]
    assert _codes(pieces_list(q=epc_of(kept.item_code), state='all', today=TODAY)) == [kept.item_code]
    assert len(pieces_list(q=kept.name[:3], state='all', today=TODAY)['pieces']) == 3
    assert _codes(pieces_list(q='لا اسم كهذا', state='all', today=TODAY)) == []


def test_sorted_and_paged_by_the_server(three):
    first = pieces_list(state='all', sort='weight', descending=False, per_page=2, page=1, today=TODAY)
    assert _codes(first) == [three['returned'].item_code, three['sold'].item_code]
    assert (first['total'], first['page'], first['per_page']) == (3, 1, 2)
    second = pieces_list(state='all', sort='weight', descending=False, per_page=2, page=2, today=TODAY)
    assert _codes(second) == [three['kept'].item_code]


def test_the_summary_is_the_shops_whatever_the_filter(three):
    summary = pieces_list(q='لا اسم كهذا', today=TODAY)['summary']
    assert summary == {'in_stock_count': 1, 'in_stock_weight': 6.5, 'in_stock_untagged': 0,
                       'sold_this_month': 1}


def test_a_catalogue_item_is_not_a_piece(three):
    db.session.add(Item(item_code='I-999001', name='صنف كتالوج', karat='21', weight=10.0, price=0.0))
    db.session.flush()
    assert 'I-999001' not in _codes(pieces_list(state='all', today=TODAY))


def test_a_filter_it_does_not_know_is_refused(three):
    for bad in ({'state': 'lost'}, {'sort': 'price'}, {'page': 0}, {'per_page': 500}):
        with pytest.raises(PiecesFilterInvalid):
            pieces_list(today=TODAY, **bad)


def test_the_route_carries_it(auth_headers, three):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/pieces?state=all&per_page=2&sort=weight&dir=asc',
                                       headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert {'pieces', 'total', 'page', 'per_page', 'summary'} <= set(body)
    assert [p['item_code'] for p in body['pieces']] == [three['returned'].item_code, three['sold'].item_code]
    g.pop('current_user', None)
    refused = flask_app.test_client().get('/api/pieces?state=lost', headers=auth_headers)
    assert refused.status_code == 400 and refused.get_json()['error'] == 'pieces_filter_invalid'
