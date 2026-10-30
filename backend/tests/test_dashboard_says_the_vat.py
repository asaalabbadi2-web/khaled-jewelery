"""The manager's dashboard says the VAT (DASH-8).

The owner, 30 Oct 2026, agreeing to all advised: the dashboard said nothing of
the VAT. Now by the return's own reading (period_vat -- what a return would
close), in the returns screen's quarters: this quarter so far, the last whole
one and whether a return covers it, and what the filed returns left owed on
the settlement account.

Run:
    python -m pytest tests/test_dashboard_says_the_vat.py -v
"""
from datetime import date, datetime

import pytest

from services.dashboard_vat import vat_due
from tests.test_vat_return_filing import _entry, books  # noqa: F401 -- the filing's own books


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_the_quarter_the_last_one_and_what_is_owed(books):  # noqa: F811
    b = books
    _entry(datetime(2034, 2, 10), [(b['cash'], 1500.0), (b['output'], -1500.0)])
    _entry(datetime(2034, 2, 12), [(b['input'], 300.0), (b['cash'], -300.0)])
    _entry(datetime(2034, 4, 3), [(b['cash'], 200.0), (b['output'], -200.0)])
    today = date(2034, 5, 15)
    before = vat_due(today)

    assert before['last_quarter']['start'] == '2034-01-01' and before['last_quarter']['end'] == '2034-03-31'
    assert before['last_quarter']['net'] == pytest.approx(1200.0)
    assert before['last_quarter']['filed'] is False
    assert before['quarter']['net'] == pytest.approx(200.0), 'April so far'

    from services.vat_return import file_vat_return
    file_vat_return(start=date(2034, 1, 1), end=date(2034, 3, 31), by='t', now=datetime(2034, 5, 15, 10))
    after = vat_due(today)
    assert after['last_quarter']['filed'] is True
    assert after['owed'] - before['owed'] == pytest.approx(1200.0), 'owed to the authority'


def test_the_dashboard_carries_it(app, auth_headers):
    vat = app.test_client().get('/api/dashboard/admin', headers=auth_headers).get_json()['vat']
    assert vat and {'quarter', 'last_quarter', 'owed', 'policy'} <= set(vat)
