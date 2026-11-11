"""A customer's return gives gold back; a correction is «تصحيح فاتورة» (the owner, 11 Nov 2026).

The return audit: 3399 and 3442 «returned» 20 and 50 riyals with no gold --
«خطأ تسجيل», «تعديل زيادة غير حقيقية» -- and 3395 carried a line of no
weight and no price beside its real one. On the 10 Nov copy a line of no
weight and no price refunding 20 was saved. The owner: «يرفض». A customer's
return whose lines give no gold back is refused, saying where a correction
is made; and a line of no weight and no price is refused in any return.

Run:
    python -m pytest tests/test_return_without_gold.py -v
"""
import pytest

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


def _refused(resp, code):
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == code, body
    return body


def test_money_back_with_no_gold_is_a_correction_not_a_return(auth_headers, world):
    sale = _sale(auth_headers, world)
    body = _refused(_post(auth_headers, _return(world, sale, [('خاتم', 0.0, 1, 20.0)])), 'return_without_gold')
    assert 'تصحيح فاتورة' in body['message']


def test_a_line_of_no_weight_and_no_price_is_refused_beside_a_real_one(auth_headers, world):
    sale = _sale(auth_headers, world)
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0), ('طقم', 0.0, 1, 0.0)]))
    _refused(resp, 'return_line_empty')


def test_a_return_of_gold_is_taken(auth_headers, world):
    sale = _sale(auth_headers, world)
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert resp.status_code == 201, resp.get_json()
