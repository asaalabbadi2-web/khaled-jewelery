"""CHART-002 release 5b: the last live accounts found by number are roles, and
what built the chart or failed for want of its numbers is gone.

Gone: the payment-system seed route (it deleted every payment method on
«force» and built 1111..1117 by number; no screen called it), the wage-release
route (its accounts 71340/7340 never existed on production: it always failed),
Account.create_parallel_account with its number-prefix whitelist (it built the
parents' twins by recursion).
"""
import uuid

import pytest

from app import app as flask_app
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
from account_pair_service import link_accounts
from models import Account, AccountingMapping, Supplier, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _n():
    return uuid.uuid4().int % 10**6


def test_what_built_the_chart_or_always_failed_is_gone(auth_headers):
    from flask import g
    assert not hasattr(Account, 'create_parallel_account')
    assert not hasattr(Account, '_PARALLEL_ALLOWED_PREFIXES')
    for path in ('/api/initialize-payment-system', '/api/release-wage-weight'):
        g.pop('current_user', None)
        assert flask_app.test_client().post(path, json={}, headers=auth_headers).status_code in (404, 405), path


def _supplier():
    from party_account_service import ensure_supplier_accounts
    s = Supplier(supplier_code=f'S-{_n()}', name=f'مورد {_n()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    return s


def _map_equity(account):
    row = AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                            account_type='opening_balance_equity').first()
    row.account_id = account.id
    db.session.flush()


def test_an_opening_balance_is_set_against_the_role_and_its_twin():
    from models import JournalEntryLine
    from offices_routes import _create_opening_entry_for_supplier
    equity = db.session.get(Account, require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'opening_balance_equity'))
    supplier = _supplier()
    _create_opening_entry_for_supplier(supplier, 1000.0, 5.0)
    touched = {l.account_id for l in JournalEntryLine.query.filter(
        JournalEntryLine.account_id.in_([equity.id, equity.memo_account_id])).all()}
    assert touched == {equity.id, equity.memo_account_id}


def test_a_gold_opening_balance_against_an_equity_with_no_twin_is_refused():
    from offices_routes import _create_opening_entry_for_supplier
    lone = Account(account_number=f'39{_n():06d}', name='حقوق بلا توأم', type='Equity', transaction_type='cash')
    db.session.add(lone)
    db.session.flush()
    _map_equity(lone)
    with pytest.raises(ValueError, match='بلا حساب وزني مربوط'):
        _create_opening_entry_for_supplier(_supplier(), 0.0, 5.0)


def test_the_cash_weight_side_is_the_cash_groups_linked_twin():
    from accounting.chart_tree import CASH_ROOT, role_account_id, twin_id
    group = Account(account_number=f'11{_n():06d}', name='نقدية', type='Asset', transaction_type='cash')
    twin = Account(account_number=f'99{_n():06d}', name='نقدية وزني', type='Asset', transaction_type='gold',
                   tracks_weight=True)
    db.session.add_all([group, twin])
    db.session.flush()
    link_accounts(group, twin, created_by='test')
    row = AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=CASH_ROOT).first()
    row.account_id = group.id
    db.session.flush()
    assert twin_id(role_account_id(CASH_ROOT)) == twin.id     # its link, whatever its number
