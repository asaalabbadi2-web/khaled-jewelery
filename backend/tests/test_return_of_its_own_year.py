"""A return is of an invoice of its own year (ADR-044, the owner, 12 Oct 2026).

«مرتجع بيع من 2026 يأتي في 2027: مرفوض -- المرتجع لا يكون إلا لفاتورة من
سنته (قانون: يُرفض في الخادم باختبار)». Each year is its own database, so in
2027's a 2026 invoice is not there at all (404); this is the law where both
could meet -- a return dated in 2027 typed into 2026's database on the year's
first morning, before the switch. The year is the return's date's against its
original's.

Run:
    python -m pytest tests/test_return_of_its_own_year.py -v
"""
from datetime import date, datetime

import pytest

from services.fiscal_year import ReturnOfAnotherYear, refuse_return_of_another_year
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_return_within_its_original import _paid_sale, _post, _return_of, app  # noqa: F401


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_the_rule():
    refuse_return_of_another_year(datetime(2026, 3, 1), datetime(2026, 12, 31, 23, 59))
    refuse_return_of_another_year(date(2026, 3, 1), date(2026, 3, 2))
    with pytest.raises(ReturnOfAnotherYear, match='2026'):
        refuse_return_of_another_year(datetime(2026, 12, 30), datetime(2027, 1, 2))
    refuse_return_of_another_year(None, datetime(2027, 1, 2))     # an original with no date: nothing to say


def test_a_sale_s_return_dated_the_next_year_is_refused(auth_headers, world):
    sale = _paid_sale(auth_headers, world)
    year = datetime.fromisoformat(sale['date']).year
    payload = _return_of(world, sale, total=1000.0)
    payload['date'] = datetime(year + 1, 1, 2, 10, 0).isoformat()
    resp = _post(auth_headers, payload)
    assert resp.status_code == 400, resp.get_json()
    assert resp.get_json()['error'] == 'return_of_another_year'
    assert str(year) in resp.get_json()['message']
