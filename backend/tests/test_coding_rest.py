"""«إقفال الباقي» (the owner, 25 Nov 2026: «ابنه»): what of a receipt line or
a batch no piece took -- the scale's drift -- closed onto the count's
shortage by its own entry, once, within the tolerance (0.05 g); beyond it, a
count's. services/coding_rest.py.

Run:
    python -m pytest tests/test_coding_rest.py -v
"""
import pytest
from flask import g

from models import CodingRestClose, JournalEntry, JournalEntryLine, Settings, db
from services.coding_rest import close_rest
from services.pieces import (PieceRefused, batch_rest, coding_view, line_rest, line_view, pending_lines,
                             register_piece)
from services.stock_ledger import category_held
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_piece_sale import _piece
from tests.test_receiving_correction import showroom  # noqa: F401
from tests.test_stock_coding import _open, _stock, bangles, receiving  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _refused(call):
    with pytest.raises(PieceRefused) as refused:
        call()
    return refused.value.code


@pytest.fixture
def coded(app, world, roles, showroom, bangles, receiving):
    """A batch of 30 g coded into three pieces weighing 29.97 g: 0.03 g left."""
    _stock(showroom, bangles, 30.0)
    batch = _open(showroom, bangles, 30.0)
    for w in (10.01, 9.98, 9.98):
        register_piece(batch, weight=w, wage=12.0, by='t', now=NOW)
    return batch


def test_a_batchs_drift_is_closed_onto_the_shortage(coded, showroom, bangles, roles):
    assert batch_rest(coded) == 0.03 and coding_view(coded)['rest_closable'] is True
    held = category_held(showroom, 21, bangles.id)
    closed = close_rest(coded, reason='فرق الميزان', by='t', now=NOW)
    assert closed.grams == 0.03
    assert batch_rest(coded) == 0.0, 'nothing left to code'
    assert round(held - category_held(showroom, 21, bangles.id), 3) == 0.03, 'out of its category, under no piece'
    lines = JournalEntryLine.query.filter_by(journal_entry_id=closed.journal_entry_id).all()
    assert {(l.account_id, round(l.credit_21k or 0, 3), round(l.debit_21k or 0, 3)) for l in lines} == {
        (showroom.account_id, 0.03, 0.0), (roles['shortage_w'].id, 0.0, 0.03)}, 'by weight alone, on the shortage'
    assert all(not (l.cash_debit or l.cash_credit) for l in lines)
    entry = db.session.get(JournalEntry, closed.journal_entry_id)
    assert (entry.reference_type, entry.reference_id) == ('coding_rest', closed.id)
    view = coding_view(coded)
    assert (view['rest'], view['rest_closable'], view['rest_closed']) == (0.0, False, 0.03)
    assert coded.id not in {v['coding_id'] for v in pending_lines()}, 'off the station\'s list'


def test_once_with_a_reason_and_only_what_is_left(coded):
    assert _refused(lambda: close_rest(coded, reason=' ', by='t', now=NOW)) == 'rest_reason_required'
    close_rest(coded, reason='فرق الميزان', by='t', now=NOW)
    assert _refused(lambda: close_rest(coded, reason='ثانية', by='t', now=NOW)) == 'rest_closed_already'
    assert CodingRestClose.query.filter_by(coding_id=coded.id).count() == 1


def test_beyond_the_tolerance_it_is_a_counts(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 30.0)
    batch = _open(showroom, bangles, 30.0)
    register_piece(batch, weight=29.9, wage=12.0, by='t', now=NOW)               # 0.10 g left
    assert coding_view(batch)['rest_closable'] is False
    assert _refused(lambda: close_rest(batch, reason='x', by='t', now=NOW)) == 'rest_over_tolerance'
    Settings.query.first().coding_rest_tolerance = 0.10                          # policy: the setting's
    assert close_rest(batch, reason='x', by='t', now=NOW).grams == 0.1


def test_a_receipt_lines_drift_too(auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)          # 20 g: 14.37 coded
    from models import InvoiceItem
    line = db.session.get(InvoiceItem, piece.receipt_item_id)
    assert _refused(lambda: close_rest(line, reason='x', by='t', now=NOW)) == 'rest_over_tolerance'
    register_piece(line, weight=5.6, by='t', now=NOW)                            # 0.03 g left
    assert line_view(line)['rest_closable'] is True
    close_rest(line, reason='فرق الميزان', by='t', now=NOW)
    assert line_rest(line) == 0.0, 'neither coded nor returned under no piece'
    with pytest.raises(PieceRefused):
        register_piece(line, weight=0.03, by='t', now=NOW)


def test_the_station_closes_it(auth_headers, coded):
    from app import app as flask_app
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/pieces/rest-close', headers=auth_headers,
                                        json={'coding_id': coded.id, 'reason': 'فرق الميزان'})
    assert resp.status_code == 201, resp.get_json()
    assert resp.get_json()['line']['rest'] == 0.0
    g.pop('current_user', None)
    again = flask_app.test_client().post('/api/pieces/rest-close', headers=auth_headers,
                                         json={'coding_id': coded.id, 'reason': 'x'})
    assert again.status_code == 400 and again.get_json()['error'] == 'rest_closed_already'


def test_kept_as_written(coded):
    closed = close_rest(coded, reason='فرق الميزان', by='t', now=NOW)
    closed.grams = 0.01
    with pytest.raises(ValueError):
        db.session.flush()
    db.session.rollback()


# ── the other way: the last piece heavier than the rest (the owner, 25 Nov 2026:
# «ماذا ان كان الفرق سالب؟» -- «ابنه») ──────────────────────────────────────

def test_a_last_piece_heavier_by_the_drift_registers_its_excess_the_surplus(app, world, roles, showroom, bangles,
                                                                           receiving):
    from services.pieces import weigh
    _stock(showroom, bangles, 30.0)
    batch = _open(showroom, bangles, 30.0)
    register_piece(batch, weight=20.0, wage=12.0, by='t', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        register_piece(batch, weight=10.02, wage=12.0, by='t', now=NOW)
    assert refused.value.code == 'piece_heavier_than_rest'
    assert refused.value.detail == {'over_rest': 0.02, 'over_rest_closable': True}, 'said, and what may be done'
    held = category_held(showroom, 21, bangles.id)
    piece = register_piece(batch, weight=10.02, wage=12.0, by='t', now=NOW, over_rest_reason='فرق الميزان')
    assert round(piece.weight, 3) == 10.02, 'registered whole, as weighed'
    assert batch_rest(batch) == 0.0 and coding_view(batch)['rest_closed'] == -0.02
    assert round(category_held(showroom, 21, bangles.id) - held, 3) == 0.02, 'the excess into its category'
    closed = CodingRestClose.query.filter_by(coding_id=batch.id).one()
    lines = JournalEntryLine.query.filter_by(journal_entry_id=closed.journal_entry_id).all()
    assert {(l.account_id, round(l.debit_21k or 0, 3), round(l.credit_21k or 0, 3)) for l in lines} == {
        (showroom.account_id, 0.02, 0.0), (roles['surplus_w'].id, 0.0, 0.02)}, 'by weight alone, from the surplus'
    assert _refused(lambda: weigh(batch, weight=0.01, over_rest_ok=True)) == 'piece_heavier_than_rest', \
        'closed once: no second excess'


def test_beyond_the_drift_a_heavier_piece_is_refused_as_before(app, world, roles, showroom, bangles, receiving):
    _stock(showroom, bangles, 40.0)
    batch = _open(showroom, bangles, 30.0)
    register_piece(batch, weight=20.0, wage=12.0, by='t', now=NOW)
    with pytest.raises(PieceRefused) as refused:
        register_piece(batch, weight=10.2, wage=12.0, by='t', now=NOW, over_rest_reason='فرق الميزان')
    assert (refused.value.code, refused.value.detail['over_rest_closable']) == ('piece_heavier_than_rest', False)
    assert CodingRestClose.query.filter_by(coding_id=batch.id).count() == 0, 'nothing written'


def test_a_receipt_lines_last_piece_too_and_once(auth_headers, world, roles, showroom, bangles_by_the_piece):
    piece = _piece(auth_headers, world, showroom, bangles_by_the_piece)          # 20 g: 14.37 coded, 5.63 left
    from models import InvoiceItem
    line = db.session.get(InvoiceItem, piece.receipt_item_id)
    last = register_piece(line, weight=5.66, by='t', now=NOW, over_rest_reason='فرق الميزان')
    assert round(last.weight, 3) == 5.66 and line_rest(line) == 0.0
    assert _refused(lambda: close_rest(line, reason='x', by='t', now=NOW)) == 'rest_closed_already'


def test_the_station_says_it_and_registers_it(auth_headers, app, world, roles, showroom, bangles, receiving):
    from app import app as flask_app
    _stock(showroom, bangles, 30.0)
    batch = _open(showroom, bangles, 30.0)
    register_piece(batch, weight=20.0, wage=12.0, by='t', now=NOW)
    g.pop('current_user', None)
    said = flask_app.test_client().get(f'/api/pieces/weigh?coding_id={batch.id}&weight=10.02',
                                       headers=auth_headers).get_json()['refused']
    assert (said['over_rest'], said['over_rest_closable']) == (0.02, True)
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/pieces', headers=auth_headers, json={
        'coding_id': batch.id, 'weight': 10.02, 'wage': 12.0, 'over_rest_reason': 'فرق الميزان'})
    assert resp.status_code == 201, resp.get_json()
