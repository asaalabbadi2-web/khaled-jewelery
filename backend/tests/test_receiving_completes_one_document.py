"""Received, then completed: one document, two entries, the whole (ADR-087 §1, §1أ, law 2).

Option B (the owner, 8 Nov 2026): receiving makes the purchase document and
posts its gold; the invoice completing it posts its cash on the same
document, a second entry -- no new invoice, no line twice. For each purchase
shape the tests hold, the document received then completed carries the lines
the purchase posted whole carries, its gold obligations and items as one; the
completion refuses a document not received, weights other than the receipt's
(the third control), and comes back the same when sent again, writing
nothing (the fourth).

Run:
    python -m pytest tests/test_receiving_completes_one_document.py -v
"""
import pytest

from models import Invoice, InvoiceGoldObligation, InvoiceItem, InvoiceKaratLine, JournalEntry
from tests.test_receiving_parts_are_the_whole import RECEIVING_SHAPES, _lines
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401 -- the VAT roles mapped


def _call(auth_headers, payload, **kw):
    from app import app as flask_app
    from flask import g
    from routes.invoices import add_invoice
    g.pop('current_user', None)
    with flask_app.test_request_context('/api/invoices', method='POST', json=payload, headers=auth_headers):
        rv = add_invoice(defer_commit=True, **kw)
    resp, status = (rv[0], rv[1]) if isinstance(rv, tuple) else (rv, 201)
    return int(status), resp.get_json()


def _id(body):
    return (body.get('invoice') or body)['id']


def _received(auth_headers, payload):
    status, body = _call(auth_headers, payload, posting_part='gold')
    assert status == 201, body
    return _id(body)


def _entries(invoice_id):
    return JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id, is_deleted=False).count()


@pytest.mark.parametrize('shape', list(RECEIVING_SHAPES))
def test_received_then_completed_is_the_whole_on_one_document(auth_headers, world, shape):
    build = RECEIVING_SHAPES[shape]
    status, body = _call(auth_headers, build(world))
    assert status == 201, body
    whole = _id(body)
    receipt = _received(auth_headers, build(world))
    assert Invoice.query.get(receipt).receiving_stage == 'received'
    status, body = _call(auth_headers, build(world), posting_part='cash', complete_invoice_id=receipt)
    assert status in (200, 201), body
    assert _id(body) == receipt, 'the same document, no new invoice'
    assert Invoice.query.get(receipt).receiving_stage == 'invoiced'
    assert _lines(receipt) == _lines(whole), 'two entries, the whole, nothing twice'
    assert _entries(receipt) == 2
    assert InvoiceItem.query.filter_by(invoice_id=receipt).count() == InvoiceItem.query.filter_by(invoice_id=whole).count()
    assert (InvoiceKaratLine.query.filter_by(invoice_id=receipt).count()
            == InvoiceKaratLine.query.filter_by(invoice_id=whole).count()), 'its karat lines once'
    assert (InvoiceGoldObligation.query.filter_by(invoice_id=receipt).count()
            == InvoiceGoldObligation.query.filter_by(invoice_id=whole).count())


def test_completed_again_it_comes_back_the_same_writing_nothing(auth_headers, world):
    build, _ = SHAPES['items only, no VAT']
    receipt = _received(auth_headers, build(world))
    _call(auth_headers, build(world), posting_part='cash', complete_invoice_id=receipt)
    entries = _entries(receipt)
    status, body = _call(auth_headers, build(world), posting_part='cash', complete_invoice_id=receipt)
    assert status == 200 and _id(body) == receipt
    assert _entries(receipt) == entries


def test_weights_other_than_the_receipts_are_refused(auth_headers, world):
    build, _ = SHAPES['items only, no VAT']
    receipt = _received(auth_headers, build(world))
    other = build(world)
    other['items'][0]['weight'] = 19.5
    status, body = _call(auth_headers, other, posting_part='cash', complete_invoice_id=receipt)
    assert status == 400 and body['error'] == 'receipt_weights_differ', body
    assert Invoice.query.get(receipt).receiving_stage == 'received'


def test_only_a_received_document_is_completed(auth_headers, world):
    build, _ = SHAPES['items only, no VAT']
    status, body = _call(auth_headers, build(world))
    status, body = _call(auth_headers, build(world), posting_part='cash', complete_invoice_id=_id(body))
    assert status == 400 and body['error'] == 'not_a_receipt', body


def test_one_key_one_document(auth_headers, world):
    build, _ = SHAPES['items only, no VAT']
    payload = dict(build(world), request_key='screen-attempt-1')
    first = _received(auth_headers, payload)
    status, body = _call(auth_headers, payload, posting_part='gold')
    assert status == 200 and _id(body) == first, 'sent again, the same document'
    assert Invoice.query.filter_by(request_key='screen-attempt-1').count() == 1


def test_from_its_day_new_gold_is_received_first(auth_headers, world):
    from datetime import date
    from models import Settings, db
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    build, _ = SHAPES['items only, no VAT']
    status, body = _call(auth_headers, build(world))
    assert status == 400 and body['error'] == 'receiving_first', body
    assert _received(auth_headers, build(world))


def test_a_received_document_is_not_unposted_nor_so_rejected(auth_headers, world):
    from app import app as flask_app
    from flask import g
    from models import Settings, db
    Settings.query.first().allow_unposting = True   # the route is on: its refusal is the receipt's
    db.session.flush()
    build, _ = SHAPES['items only, no VAT']
    receipt = _received(auth_headers, build(world))
    for url in (f'/api/invoices/{receipt}/unpost', f'/api/invoices/unpost/{receipt}'):
        g.pop('current_user', None)
        resp = flask_app.test_client().post(url, headers=auth_headers, json={})
        assert resp.status_code == 409 and resp.get_json()['error'] == 'received_document', url
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api/invoices/{receipt}/reject', headers=auth_headers, json={})
    assert resp.status_code == 400, 'posted: never rejected'
    assert Invoice.query.get(receipt).is_posted


def test_two_stations_one_key_at_once_one_document(auth_headers, world, monkeypatch):
    """The race (the owner, 8 Nov 2026: «محطتين مختلفتين في اللحظة نفسها»): both
    ask whether the key was saved before either has saved it; the second's
    insert meets the first's row on the unique key. It was a 500; it is the
    first's document, nothing written twice."""
    from models import db
    import routes.invoices as invoices
    build, _ = SHAPES['items only, no VAT']
    payload = dict(build(world), request_key='two-stations')
    first = _received(auth_headers, payload)
    entries = JournalEntry.query.count()
    real = invoices._saved_under_key
    calls = []

    def not_yet(key):              # the second asked before the first was saved
        calls.append(key)
        return None if len(calls) == 1 else real(key)
    monkeypatch.setattr(invoices, '_saved_under_key', not_yet)
    status, body = _call(auth_headers, payload, posting_part='gold')
    assert status == 200 and _id(body) == first, body
    assert Invoice.query.filter_by(request_key='two-stations').count() == 1
    assert JournalEntry.query.count() == entries, 'no entry written twice'
