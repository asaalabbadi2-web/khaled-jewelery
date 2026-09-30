"""A non-numeric account number never stops the next one from being generated.

account_number_generator cast account_number to BIGINT in SQL, next to a
length and prefix filter it trusted to run first. SQL promises no order: on
PostgreSQL an account number such as '2100-T1' -- length 7, prefix '2100' --
reached the cast and failed the query, so no office, supplier or customer
account could be created under 2100. SQLite cast it leniently and hid it; it
surfaced when the tests moved to PostgreSQL (TEST-001, 30 Sep 2026).

Run:
    python -m pytest tests/test_account_number_generator_text_numbers.py -v
"""
import pytest

from app import app as flask_app
from account_number_generator import (
    get_customer_account_capacity,
    get_next_account_number,
    get_next_party_account_number,
)
from models import Account, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number):
    db.session.add(Account(account_number=number, name=f'حساب {number}', type='Liability'))
    db.session.flush()


def test_a_text_number_in_the_range_is_ignored_not_fatal():
    _account('2107')
    _account('2107000')
    _account('2107-T1')          # same length and prefix as the detail range 2107000..2107999
    assert get_next_account_number('2107') == '2107001'


def test_the_party_generator_and_the_capacity_read_the_same_way():
    _account('213')
    _account('2130')
    _account('213A')             # 4 characters under the 2130..2229 party range
    assert get_next_party_account_number('213') == '2131'
    _account('2140000')
    _account('214000X')
    assert get_customer_account_capacity('2140')['used'] == 1
