"""CHART-002 step 4c2: the weight-closing execution profiles find their expense
account by role, and nothing builds the chart at startup.

The profiles (cleaning, melting, logistics, valuation difference) read account
numbers from config (5110/7510, 5120/7520, 5130/7530, 3600/7600) that production
never had -- every profile answered «الحساب المالي للبروفايل غير متوفر» -- and
the startup built those lists' accounts and relinked twins by number (1310's as
71310000, the scrap box). The owner, 14 Oct 2026: the screen stays, its accounts
are roles; the chart is data.
"""
import uuid

import pytest

from app import app as flask_app
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from account_pair_service import link_accounts
from models import Account, AccountingMapping, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _post(path, body, headers):
    from flask import g
    g.pop('current_user', None)
    return flask_app.test_client().post(path, json=body, headers=headers)


def test_an_unmapped_profile_is_refused_by_its_role(auth_headers):
    resp = _post('/api/weight-closing/execute-profile', {'profile_key': 'cleaning', 'cash_amount': 100.0},
                 auth_headers)
    assert resp.status_code == 400
    assert 'weight_profile_cleaning' in resp.get_json()['message']


def test_a_mapped_profile_finds_its_account_and_its_linked_twin():
    from services.weight_execution import resolve_weight_profile
    n = uuid.uuid4().int % 10**6
    expense = Account(account_number=f'51{n:06d}', name='مصاريف صهر', type='Expense', transaction_type='cash')
    twin = Account(account_number=f'99{n:06d}', name='مصاريف صهر وزني', type='Expense', transaction_type='gold',
                   tracks_weight=True)
    db.session.add_all([expense, twin])
    db.session.flush()
    link_accounts(expense, twin, created_by='test')
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='weight_profile_melting',
                                     account_id=expense.id, is_active=True, created_by='test'))
    db.session.flush()

    profile = resolve_weight_profile('melting')

    assert profile['financial_account'].id == expense.id
    assert profile['memo_account'].id == twin.id        # the link, whatever its number


def test_the_startup_builds_no_account():
    import pathlib
    root = pathlib.Path(__file__).resolve().parents[1]
    for path, gone in (('app.py', ('seed_chart_of_accounts_if_empty', 'ensure_weight_closing_support_accounts',
                                   'ensure_bonus_accounts', "_ensure_account('1500'")),
                       ('config.py', ('WEIGHT_SUPPORT_ACCOUNTS = [',)),
                       ('schema_guard.py', ('def ensure_bonus_accounts',))):
        text = (root / path).read_text(encoding='utf-8')
        assert not [g for g in gone if g in text], path
