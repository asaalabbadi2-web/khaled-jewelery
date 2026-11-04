"""The bonuses owed on a day: the approved, unpaid documents beside what the books owe (REPORTS ت6-3, ADR-083).

The books are right (BONUS-BOOKS-1; the owner, 14 Oct 2026): a voucher, its
reversal or a manual entry on an employee's bonus account changes what he is
owed without passing through the bonus. So each employee says, on a day: his
bonuses approved and neither paid nor reversed by then, their count and sum;
what the books owe on his bonus account to its end; and the difference -- a
finding, the books' side being the truth. What the bonus payables hold beside
the employees' accounts is said apart. The check: the documents agree with
the books, or by how much they do not.

Run:
    python -m pytest tests/test_report_bonus_payables.py -v
"""
import datetime as dt

import pytest

from tests.test_payroll_bonuses import _approved_bonus, _paid_outside, employee  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _report(day=dt.date(2099, 12, 31)):
    from services.reports.bonus_payables import bonus_payables
    return bonus_payables(as_of=day, now=dt.datetime(2099, 12, 31))


def _row(report, emp):
    return next(r for r in report.rows if r.get('drill') == {'kind': 'employee', 'id': emp})


def test_an_approved_bonus_is_owed_by_the_documents_and_the_books(auth_headers, employee):
    _approved_bonus(auth_headers, employee, amount=1500.0)
    report = _report()
    row = _row(report, employee)
    assert (row['count'], row['documents'], row['books'], row['difference']) == (1, 1500.0, 1500.0, None)
    assert {c.key: c.ok for c in report.checks}['books_agree'] is True


def test_paid_outside_the_bonus_the_books_owe_less_and_say_so(auth_headers, employee):
    _approved_bonus(auth_headers, employee, amount=1500.0)
    _paid_outside(employee, 500.0)
    report = _report()
    row = _row(report, employee)
    assert (row['documents'], row['books'], row['difference']) == (1500.0, 1000.0, 500.0)
    assert row['style'] == 'finding'
    check = {c.key: c for c in report.checks}['books_agree']
    assert not check.ok and '500.00' in check.label


def test_a_day_before_its_approval_owes_nothing(auth_headers, employee):
    _approved_bonus(auth_headers, employee)
    assert all(r.get('drill') != {'kind': 'employee', 'id': employee} for r in _report(dt.date(2000, 1, 1)).rows)
