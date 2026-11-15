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
    vat = app.test_client().get('/api/dashboard/admin/standing', headers=auth_headers).get_json()['vat']
    assert vat and {'quarter', 'last_quarter', 'owed', 'policy'} <= set(vat)


def test_a_filed_quarter_says_its_return_not_the_closed_books(books):  # noqa: F811
    """15 Nov 2026: the card said 0 / 0 for a quarter filed at 4,137.68 due --
    the filing closes the books' VAT accounts, and a reading after it finds
    them empty. A quarter a return covers says the return's own figures."""
    from services.vat_return import file_vat_return
    b = books
    _entry(datetime(2034, 2, 10), [(b['cash'], 1500.0), (b['output'], -1500.0)])
    _entry(datetime(2034, 2, 12), [(b['input'], 300.0), (b['cash'], -300.0)])
    file_vat_return(start=date(2034, 1, 1), end=date(2034, 3, 31), by='t', now=datetime(2034, 5, 15, 10))
    last = vat_due(date(2034, 5, 15))['last_quarter']
    assert last['source'] == 'return' and last['filed'] is True
    assert (last['output_vat'], last['input_vat'], last['net']) == (1500.0, 300.0, 1200.0)


def test_while_sales_carry_no_vat_the_output_is_the_returns_to_say(books, monkeypatch):  # noqa: F811
    """«لكم 5,692.68» with the output nothing: the sales are not charged VAT in
    the books, so this quarter's output is the return's; the input alone is said."""
    import services.vat_policy as vat_policy
    b = books
    _entry(datetime(2034, 4, 12), [(b['input'], 300.0), (b['cash'], -300.0)])
    monkeypatch.setattr(vat_policy, 'policy_on', lambda day: vat_policy.Policy(True, False))
    quarter = vat_due(date(2034, 5, 15))['quarter']
    assert quarter['output_at_filing'] is True
    assert quarter['output_vat'] is None and quarter['net'] is None, 'not «لكم»: the output is not yet known'
    assert quarter['input_vat'] == pytest.approx(300.0)
