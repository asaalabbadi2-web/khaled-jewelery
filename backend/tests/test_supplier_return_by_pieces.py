"""A coded receipt line goes back to its supplier by its pieces (the owner, 18 Nov 2026).

Probed on a copy of the 17 Nov production, a receipt line of 200 g coded
into ten pieces: 44 g returned as the purchase screen sends it -- the line,
no piece -- left the category under no piece (nine pieces held 187 g, the
category 143 g); a sold piece named was returned too (−13 g of it). Now a
piece named is of its line, in the stock, whole, once, and where the return
takes its gold from; a coded line's grams under no piece no more than its
rest -- the same rest the coding reads, so gold returned is not coded.

Run:
    python -m pytest tests/test_supplier_return_by_pieces.py -v
"""
import uuid
from datetime import datetime

from models import InvoiceItem, JournalEntry, JournalEntryLine, SafeBox, Account, db
from services.pieces import PieceRefused, line_view, piece_held, register_piece
from services.stock_ledger import allocate
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_sale import _piece
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_return_takes_its_piece import _cash, _piece_moves, _post, _sell, as_production  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _back(world, line, *lines):
    """A supplier's return of the receipt's line: (grams, piece or None) each."""
    return {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': world['supplier'].id,
        'original_invoice_id': line.invoice_id, 'gold_type': 'new', 'date': datetime.now().isoformat(),
        'total': 0.0, 'total_tax': 0.0, 'settlement_method': 'credit', 'amount_paid': 0.0, 'return_reason': 'عيب',
        'items': [{'name': 'بنجرة', 'karat': 21, 'weight': grams, 'quantity': 1, 'manufacturing_wage_per_gram': 15.0,
                   'wage_per_gram': 15.0, 'wage_total': 15.0 * grams, 'original_invoice_item_id': line.id,
                   'category_id': line.category_id, 'item_id': piece.id if piece else None}
                  for grams, piece in lines]}


def _line(piece):
    return db.session.get(InvoiceItem, piece.receipt_item_id)


def _refused(resp, code):
    assert resp.status_code == 400 and resp.get_json()['error'] == code, resp.get_json()


def test_a_piece_named_goes_back_by_its_number(auth_headers, as_production, world, roles, showroom,
                                               bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    resp = _post(auth_headers, _back(world, _line(piece), (piece.weight, piece)))
    assert resp.status_code == 201, resp.get_json()
    assert _piece_moves(resp.get_json()['id']) == [(piece.id, -piece.weight)]
    assert piece_held(piece.id) == 0.0


def test_a_coded_lines_grams_under_no_piece_are_its_rest(auth_headers, as_production, world, roles, showroom,
                                                         bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)      # 20 g: 14.37 coded, 5.63 left
    line = _line(piece)
    resp = _post(auth_headers, _back(world, line, (10.0, None)))
    _refused(resp, 'coded_line_returned_by_pieces')
    assert resp.get_json()['rest_grams'] == 5.63
    assert _post(auth_headers, _back(world, line, (5.0, None))).status_code == 201
    assert line_view(line)['rest'] == 0.63, 'the station reads what is left'
    try:
        register_piece(line, weight=5.0, by='t', now=NOW)
        raise AssertionError('the gold returned was coded')
    except PieceRefused as refused:
        assert refused.code == 'piece_heavier_than_rest'


def test_a_piece_sold_does_not_go_back(auth_headers, as_production, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    _sell(auth_headers, piece, _cash())
    _refused(_post(auth_headers, _back(world, _line(piece), (piece.weight, piece))), 'piece_not_in_stock')


def test_a_piece_goes_back_whole_once_and_of_its_line(auth_headers, as_production, world, roles, showroom,
                                                      bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    other = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    line = _line(piece)
    _refused(_post(auth_headers, _back(world, line, (6.0, piece))), 'piece_returned_whole')
    small = register_piece(line, weight=5.0, by='t', now=NOW)
    _refused(_post(auth_headers, _back(world, line, (5.0, small), (5.0, small))), 'piece_repeated')
    _refused(_post(auth_headers, _back(world, line, (other.weight, other))), 'piece_not_of_line')


def test_a_piece_goes_back_from_where_it_is(auth_headers, as_production, world, roles, showroom,
                                            bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    account = Account(account_number=f'719{uuid.uuid4().int % 10**5:05d}', name='خزينة فرع', type='Asset',
                      transaction_type='gold', tracks_weight=True)
    db.session.add(account)
    db.session.flush()
    branch = SafeBox(name=f'فرع {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=account.id, is_active=True,
                     stock_location='showroom')
    db.session.add(branch)
    je = JournalEntry(entry_number=f'JE-T-{uuid.uuid4().hex[:8]}', date=datetime(2026, 11, 18), entry_type='عادي',
                      description='نقل', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    out = JournalEntryLine(journal_entry_id=je.id, account_id=showroom.account_id, description='نقل',
                           credit_21k=piece.weight)
    into = JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='نقل', debit_21k=piece.weight)
    db.session.add_all([out, into])
    db.session.flush()
    allocate(out, 21, piece.category_id, -piece.weight, item_id=piece.id, by='t', now=NOW)
    allocate(into, 21, piece.category_id, piece.weight, item_id=piece.id, by='t', now=NOW)
    resp = _post(auth_headers, _back(world, _line(piece), (piece.weight, piece)))
    _refused(resp, 'piece_not_where_returned')
    assert resp.get_json()['safe_box_name'] == branch.name


def test_pieces_of_one_line_go_back_together(auth_headers, as_production, world, roles, showroom,
                                             bangles_by_the_piece):
    """A received line counts 1 for its 20 g: two of its pieces are not «2 of 1»."""
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    line = _line(piece)
    second = register_piece(line, weight=5.0, by='t', now=NOW)
    resp = _post(auth_headers, _back(world, line, (piece.weight, piece), (second.weight, second)))
    assert resp.status_code == 201, resp.get_json()
    assert piece_held(piece.id) == 0.0 and piece_held(second.id) == 0.0


def test_the_screen_is_told_a_coded_lines_pieces_and_rest(auth_headers, as_production, world, roles, showroom,
                                                          bangles_by_the_piece):
    from flask import g
    from app import app as flask_app
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)
    line = _line(piece)
    sold = register_piece(line, weight=3.0, by='t', now=NOW)
    _sell(auth_headers, sold, _cash())
    g.pop('current_user', None)
    body = flask_app.test_client().get(f'/api/pieces/invoices/{line.invoice_id}/coded-lines',
                                       headers=auth_headers).get_json()
    coded = body['lines'][str(line.id)]
    assert [p['item_code'] for p in coded['pieces']] == [piece.item_code], 'the sold one is not offered'
    assert coded['rest'] == 2.63


def test_a_receipt_not_invoiced_goes_back_after_its_invoice(auth_headers, as_production, world, roles, showroom,
                                                            bangles_by_the_piece):
    """The owner, 23 Nov 2026 (the cycle rehearsal, step 11: «هل يمكن ان انشئ فاتورة
    مرتجع شراء دون تسجيل فاتورة الشراء؟» -- «أضفها»): a receipt whose supplier's
    invoice is not completed has no wage known; nothing of it goes back before."""
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece, invoiced=False)
    resp = _post(auth_headers, _back(world, _line(piece), (piece.weight, piece)))
    _refused(resp, 'return_receipt_not_invoiced')
    assert 'استكملها أولًا' in resp.get_json()['message']
    assert piece_held(piece.id) == piece.weight, 'nothing written'
