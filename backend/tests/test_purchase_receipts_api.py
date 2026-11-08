"""The receiving routes (ADR-087 R2): receive, list what waits for its invoice, complete.

POST /api/purchase-receipts -- a receipt: its supplier, his paper's number, the
  key of the save attempt, its lines by category (weight received, his
  weight); the gold posted. Refused before the settings' day.
GET  /api/purchase-receipts?pending=1 -- «استلامات بلا فاتورة».
POST /api/purchase-receipts/<id>/complete -- the purchase screen's request
  completing it: its cash posted on the same document.

Run:
    python -m pytest tests/test_purchase_receipts_api.py -v
"""
from datetime import date

import pytest

from app import app as flask_app
from models import Invoice, Settings, db
from tests.test_receiving_parts_are_the_whole import _screen
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


def _post(headers, url, body):
    from flask import g
    g.pop('current_user', None)
    resp = flask_app.test_client().post(url, headers=headers, json=body)
    return resp.status_code, resp.get_json()


def _get(headers, url):
    from flask import g
    g.pop('current_user', None)
    resp = flask_app.test_client().get(url, headers=headers)
    return resp.status_code, resp.get_json()


def _receipt(world, key='r-1'):
    line = _screen(world)['items'][0]
    return {'supplier_id': world['supplier'].id, 'request_key': key, 'supplier_invoice_number': 'P-17',
            'lines': [{'category_id': line['category_id'], 'karat': 21, 'weight': 12.5, 'supplier_weight': 12.5}]}


@pytest.fixture
def receiving_on():
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()


def test_before_its_day_it_is_refused(auth_headers, world):
    Settings.query.first().receiving_from = None
    db.session.flush()
    status, body = _post(auth_headers, '/api/purchase-receipts', _receipt(world))
    assert status == 400 and body['error'] == 'receiving_not_active'


def test_received_listed_completed(auth_headers, world, receiving_on):
    status, body = _post(auth_headers, '/api/purchase-receipts', _receipt(world))
    assert status == 201, body
    receipt = body['invoice']['id']
    assert db.session.get(Invoice, receipt).receiving_stage == 'received'
    assert db.session.get(Invoice, receipt).supplier_invoice_number == 'P-17'
    status, again = _post(auth_headers, '/api/purchase-receipts', _receipt(world))
    assert status == 200 and again['invoice']['id'] == receipt, 'one key, one document'

    status, listed = _get(auth_headers, '/api/purchase-receipts?pending=1')
    assert status == 200 and receipt in [r['id'] for r in listed['receipts']]
    row = next(r for r in listed['receipts'] if r['id'] == receipt)
    assert row['weight_by_karat'] == {'21': 12.5} and row['supplier_name'] == world['supplier'].name

    status, done = _post(auth_headers, f'/api/purchase-receipts/{receipt}/complete', _screen(world))
    assert status in (200, 201), done
    assert db.session.get(Invoice, receipt).receiving_stage == 'invoiced'
    status, listed = _get(auth_headers, '/api/purchase-receipts?pending=1')
    assert receipt not in [r['id'] for r in listed['receipts']]


def test_completed_with_other_weights_refused(auth_headers, world, receiving_on):
    status, body = _post(auth_headers, '/api/purchase-receipts', _receipt(world, key='r-2'))
    other = _screen(world)
    other['items'][0]['weight'] = 12.0
    status, done = _post(auth_headers, f"/api/purchase-receipts/{body['invoice']['id']}/complete", other)
    assert status == 400 and done['error'] == 'receipt_weights_differ'
