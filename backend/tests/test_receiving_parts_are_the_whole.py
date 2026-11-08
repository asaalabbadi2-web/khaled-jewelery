"""A purchase's gold part and its cash part are its whole entry, line for line (ADR-087 §2, law 2).

Receiving posts the supplier purchase's gold (the stock's weight, the
supplier's gold), the invoice completing it its cash (wages, VAT, the cash
owed, priced stones, gold paid with it) -- never twice, nothing left out (the
owner's first control, §1أ ١). Both are the one posting in add_invoice, its
sections gated by the part; so for each shape of purchase received by
category lines (the item shapes of tests/test_supplier_purchase_effect, and
the screen's own request with its VAT), the lines its gold part
writes and the lines its cash part writes, together, are the lines it writes
whole -- and the gold part has no cash, the cash part no gold of the stock.

Run:
    python -m pytest tests/test_receiving_parts_are_the_whole.py -v
"""
from collections import Counter

import pytest

from models import JournalEntry, JournalEntryLine, db
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401 -- the VAT roles mapped

KARATS = (18, 21, 22, 24)


def _screen(w, *, gold_vat=False):
    """The purchase screen's own request (frontend/test/payloads/purchase_credit.json:
    12.5 g of 21k at 18 a gram, its wage VAT) -- with the gold's VAT too, if asked."""
    import json
    import os
    from tests.purchase_category import categorized
    path = os.path.join(os.path.dirname(__file__), '..', '..', 'frontend', 'test', 'payloads', 'purchase_credit.json')
    with open(path, encoding='utf-8') as fh:
        body = json.load(fh)
    from datetime import datetime
    # the recording holds '<date>' where the screen sends the moment
    items = [{k: v for k, v in i.items() if k not in ('category', 'category_id')} for i in body['items']]
    # the recording's category is the screen test's own (40): this database's, of its karat
    body.update(supplier_id=w['supplier'].id, items=categorized(items), date=datetime.now().isoformat())
    for key in ('branch_id', 'safe_box_id', 'payment_method_id'):
        body.pop(key, None)
    if gold_vat:
        gold_tax = round(body['gold_subtotal'] * 0.15, 2)
        body.update(apply_gold_tax=True, gold_tax_total=gold_tax, total_tax=round(body['total_tax'] + gold_tax, 2),
                    total=round(body['total'] + gold_tax, 2))
    return body


# What receiving takes: lines by category (ADR-087 §1) -- the item shapes the
# purchase tests hold, and the screen's own request, its wage VAT, its gold VAT.
RECEIVING_SHAPES = {
    **{name: build for name, (build, _) in SHAPES.items() if 'karat lines' not in name and 'gold VAT' not in name},
    "the screen's purchase on credit, wage VAT": _screen,
    "the screen's purchase, gold VAT and wage VAT": lambda w: _screen(w, gold_vat=True),
}


def _post(auth_headers, payload, part):
    from app import app as flask_app
    from routes.invoices import add_invoice
    from flask import g
    g.pop('current_user', None)
    with flask_app.test_request_context('/api/invoices', method='POST', json=payload, headers=auth_headers):
        rv = add_invoice(posting_part=part, defer_commit=True)
    resp, status = (rv[0], rv[1]) if isinstance(rv, tuple) else (rv, 201)
    assert int(status) == 201, resp.get_data(as_text=True)[:400]
    body = resp.get_json()
    return (body.get('invoice') or body)['id']


def _lines(invoice_id):
    rows = (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                    JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False)).all())
    return Counter(
        (l.account_id, round(float(l.cash_debit or 0), 2), round(float(l.cash_credit or 0), 2),
         *(round(float(getattr(l, f'{side}_{k}k') or 0), 3) for side in ('debit', 'credit') for k in KARATS))
        for l in rows)


@pytest.mark.parametrize('shape', list(RECEIVING_SHAPES))
def test_the_gold_part_and_the_cash_part_are_the_whole(auth_headers, world, shape):
    build = RECEIVING_SHAPES[shape]
    whole = _lines(_post(auth_headers, build(world), 'whole'))
    gold = _lines(_post(auth_headers, build(world), 'gold'))
    cash = _lines(_post(auth_headers, build(world), 'cash'))
    assert gold + cash == whole, 'nothing twice, nothing left out'
    assert all(line[1] == line[2] == 0 for line in gold), 'the gold part writes no cash'
    assert all(not any(line[3:]) for line in cash), 'the cash part writes no gold'


def test_received_by_category_lines_never_by_karat_lines(auth_headers, world):
    """The karat lines are the old screen's whole purchase (PURCHASE-UX-5)."""
    from app import app as flask_app
    from flask import g
    from routes.invoices import add_invoice
    build, _ = SHAPES['karat lines, wage VAT']
    g.pop('current_user', None)
    with flask_app.test_request_context('/api/invoices', method='POST', json=build(world), headers=auth_headers):
        resp, status = add_invoice(posting_part='gold', defer_commit=True)
    assert status == 400 and resp.get_json()['error'] == 'receiving_lines_by_category'
