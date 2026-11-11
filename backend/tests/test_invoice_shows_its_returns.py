"""An invoice says its returns, and a return its original (the return audit, 11 Nov 2026).

The server had them (/invoices/<id>/returns) and the app a call for them,
which no screen made: an invoice opened from the list never said it had
been returned, nor a return what it returned. The invoice's own details
carry them now -- a sale its returns (number, date, value, weight, status),
a return its original's number.

Run:
    python -m pytest tests/test_invoice_shows_its_returns.py -v
"""
import pytest
from flask import g

from app import app as flask_app
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_return_line_remaining import _post, _return, _sale


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _details(headers, invoice_id):
    g.pop('current_user', None)
    resp = flask_app.test_client().get(f'/api/invoices/{invoice_id}', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_a_sale_says_its_returns_and_a_return_its_sale(auth_headers, world):
    sale = _sale(auth_headers, world)
    assert _details(auth_headers, sale['id'])['returns'] == []
    made = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 700.0)]))
    assert made.status_code == 201, made.get_json()
    ret = made.get_json()

    returns = _details(auth_headers, sale['id'])['returns']
    assert len(returns) == 1
    assert returns[0]['id'] == ret['id'] and returns[0]['invoice_number'] == ret['invoice_number']
    assert returns[0]['total'] == 700.0 and returns[0]['total_weight'] == 2.0

    original = _details(auth_headers, ret['id'])['original_invoice']
    assert original == {'id': sale['id'], 'invoice_number': sale['invoice_number']}
