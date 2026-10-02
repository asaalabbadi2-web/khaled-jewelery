"""Editing a scrap sale corrects it; it stays a scrap sale (the owner, 2 Oct 2026).

A scrap sale is saved as «بيع» with gold_type 'scrap': its gold leaves the main
scrap safe. The invoices list chose the edit screen by invoice_type alone, so a
scrap sale opened in the ordinary sale screen -- which sends no gold_type -- and
add_invoice re-created it as a sale of new gold. Sale #1540 (3158, 29 Sep 2026)
came back as 3162: its 8 g of 22k left the display safe (30) and the display
inventory (71300) instead of the scrap safe (31); the owner saw it when the
scrap safe's 22k did not move. The data waits for stage 4 (the owner).

The law, as EDIT-001's for the number and the date: an edit keeps what kind of
invoice it is -- its type and its gold. Sent nothing, the original's stands;
sent another, the edit is refused before anything is deleted.

Run:
    python -m pytest tests/test_scrap_sale_edit_stays_scrap.py -v
"""
from datetime import datetime

import pytest

from app import app as flask_app
from models import Invoice, Settings, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    row = Settings.query.first() or Settings()
    row.auto_post_invoices = False        # held, so it can be edited
    db.session.add(row)
    db.session.flush()
    yield


def _scrap_sale(world, *, grams=8.0, gold_type='scrap'):
    """What the scrap sale screen sends (scrap_sales_invoice_screen.dart)."""
    body = {'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'transaction_type': 'sell',
            'employee_id': world['holder'].id, 'date': datetime.now().isoformat(),
            'total': 4000.0, 'total_weight': grams, 'total_cost': 0.0, 'total_tax': 0.0,
            'amount_paid': 0.0, 'payments': [],
            'items': [{'name': 'كسر', 'karat': 22, 'weight': grams, 'price': 4000.0, 'net': 4000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 4000.0}]}
    if gold_type is not None:
        body['gold_type'] = gold_type
    return body


def _held_scrap_sale(auth_headers, world):
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=_scrap_sale(world))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    data = resp.get_json()
    assert data['is_posted'] is False and data['gold_type'] == 'scrap'
    return data['id']


def _edit(auth_headers, invoice_id, body):
    return flask_app.test_client().put(f'/api/invoices/{invoice_id}', headers=auth_headers, json=body)


def test_edited_from_a_screen_that_sends_no_gold_type_it_stays_scrap(auth_headers, world):
    """3158's path: the ordinary sale screen sends no gold_type."""
    old_id = _held_scrap_sale(auth_headers, world)
    resp = _edit(auth_headers, old_id, _scrap_sale(world, grams=7.5, gold_type=None))
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    edited = db.session.get(Invoice, resp.get_json()['id'])
    assert edited.gold_type == 'scrap', f'the scrap sale became a sale of {edited.gold_type} gold'
    assert float(edited.total_weight) == 7.5


def test_edited_from_its_own_screen_it_stays_scrap(auth_headers, world):
    old_id = _held_scrap_sale(auth_headers, world)
    resp = _edit(auth_headers, old_id, _scrap_sale(world, grams=7.5))
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert db.session.get(Invoice, resp.get_json()['id']).gold_type == 'scrap'


@pytest.mark.parametrize('change', ({'gold_type': 'new'}, {'invoice_type': 'شراء من عميل'}))
def test_an_edit_that_changes_the_kind_of_invoice_is_refused_and_nothing_is_deleted(auth_headers, world, change):
    old_id = _held_scrap_sale(auth_headers, world)
    body = _scrap_sale(world, grams=7.5)
    body.update(change)
    resp = _edit(auth_headers, old_id, body)
    assert resp.status_code == 409, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'edit_changes_invoice_kind'
    original = db.session.get(Invoice, old_id)
    assert original is not None and original.gold_type == 'scrap' and float(original.total_weight) == 8.0
