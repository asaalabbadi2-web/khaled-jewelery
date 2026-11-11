"""The original-invoice picker: posted invoices, found on the server, a page at a time (the return audit, M3).

On the 10 Nov copy the picker fetched every returnable invoice at each opening
(1,878 sales for a sale's return, 0.54 MB), the six rejected and never-posted
sales among them; it named each by its row id (#3771), not its number
(SELL-2026-1982), and searched it by that id; and «what remains» was money
alone, counting cancelled returns. Now the server lists the posted, not
rejected; finds by the number as seen, the party or the amount; a page at a
time; and says what remains of each in grams and in money, by its lines
(services/return_lines.return_lines_of).

Run:
    python -m pytest tests/test_returnable_picker.py -v
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


def _picker(headers, **params):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/invoices/returnable', headers=headers,
                                       query_string={'invoice_type': 'بيع', **params})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def _number(sale):
    return sale['invoice_number']


def test_it_finds_a_sale_by_its_number_as_seen(auth_headers, world):
    sale = _sale(auth_headers, world)
    for typed in (_number(sale), _number(sale).split('-')[-1]):
        found = _picker(auth_headers, search=typed)['invoices']
        assert sale['id'] in [i['id'] for i in found], typed
        listed = next(i for i in found if i['id'] == sale['id'])
        assert listed['invoice_number'] == _number(sale)


def test_a_sale_not_posted_is_not_offered(auth_headers, world):
    held = _sale(auth_headers, world, held=True)
    found = _picker(auth_headers, search=_number(held))['invoices']
    assert held['id'] not in [i['id'] for i in found]


def test_it_says_what_remains_and_a_sale_returned_whole_is_not_offered_to_return(auth_headers, world):
    sale = _sale(auth_headers, world)
    listed = next(i for i in _picker(auth_headers, search=_number(sale))['invoices'] if i['id'] == sale['id'])
    assert listed['remaining_grams'] == 52.0 and listed['remaining_amount'] == 26000.0 and listed['can_return']
    whole = [('خاتم', 2.0, 1, 1000.0), ('بنجرة', 10.0, 5, 5000.0), ('طقم', 40.0, 1, 20000.0)]
    assert _post(auth_headers, _return(world, sale, whole)).status_code == 201
    listed = next(i for i in _picker(auth_headers, search=_number(sale))['invoices'] if i['id'] == sale['id'])
    assert listed['remaining_grams'] == 0.0 and listed['can_return'] is False


def test_a_page_at_a_time(auth_headers, world):
    for _ in range(3):
        _sale(auth_headers, world)
    body = _picker(auth_headers, per_page=2)
    assert len(body['invoices']) == 2
    assert body['has_more'] is True and body['total_count'] >= 3
    nxt = _picker(auth_headers, per_page=2, page=2)
    assert not {i['id'] for i in nxt['invoices']} & {i['id'] for i in body['invoices']}
