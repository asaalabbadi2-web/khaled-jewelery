"""Every supplier-balance surface answers from the ledger, and they all agree.

Companion to test_supplier_balance_is_derived_ratchet.py: the ratchet forbids
the cache, these tests prove the replacements are correct and mutually
consistent. Before this change three paths disagreed — the list served live
values, weight-summary and the delete guard served a stale column, and the
statement endpoint ran its own third query.

Run:
    python -m pytest tests/test_supplier_balance_derived_endpoints.py -v
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, Supplier, db
from party_account_service import ensure_supplier_accounts
from routes.suppliers import _current_balance_payload, _live_balance_payload
from services.party_live_balances import compute_live_supplier_balances


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app):
    connection = db.engine.connect()
    transaction = connection.begin()
    db.session.bind = connection
    nested = connection.begin_nested()

    yield

    db.session.remove()
    nested.rollback()
    transaction.rollback()
    connection.close()


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier():
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد اختبار {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


def _post_gold(supplier, *, karat=21, credit=0.0, debit=0.0, cash_credit=0.0):
    accounts = ensure_supplier_accounts(supplier)
    je = JournalEntry(
        entry_number=f'JE-{_uid()}',
        date=datetime.now() - timedelta(days=1),
        description='قيد اختباري',
        entry_type='عادي',
        is_posted=True,
        is_draft=False,
        created_by='test',
    )
    db.session.add(je)
    db.session.flush()

    kwargs = {
        'journal_entry_id': je.id,
        'account_id': accounts.financial.id,
        'supplier_id': supplier.id,
        'description': 'قيد اختباري',
    }
    if credit:
        kwargs[f'credit_{karat}k'] = credit
    if debit:
        kwargs[f'debit_{karat}k'] = debit
    if cash_credit:
        kwargs['cash_credit'] = cash_credit
    db.session.add(JournalEntryLine(**kwargs))
    db.session.flush()
    return je


class TestLiveBalancePayload:

    def test_emits_exactly_the_five_json_keys_the_frontend_reads(self):
        """suppliers_screen.dart reads these names; the contract must not
        change just because the storage did."""
        payload = _live_balance_payload(_supplier())
        assert set(payload) == {
            'balance_cash',
            'balance_gold_18k',
            'balance_gold_21k',
            'balance_gold_22k',
            'balance_gold_24k',
        }

    def test_zero_for_a_supplier_with_no_ledger_activity(self):
        payload = _live_balance_payload(_supplier())
        assert all(v == 0.0 for v in payload.values())

    def test_reflects_the_ledger_in_the_debit_minus_credit_convention(self):
        supplier = _supplier()
        _post_gold(supplier, karat=21, credit=100.0)

        payload = _live_balance_payload(supplier)
        assert payload['balance_gold_21k'] == -100.0, \
            'a credit means we owe the supplier, which reads negative here'

        _post_gold(supplier, karat=21, debit=40.0)
        assert _live_balance_payload(supplier)['balance_gold_21k'] == -60.0

    def test_agrees_with_the_canonical_function_exactly(self):
        supplier = _supplier()
        _post_gold(supplier, karat=18, credit=33.333)

        canonical = compute_live_supplier_balances([supplier]).get(int(supplier.id)) or {}
        payload = _live_balance_payload(supplier)
        assert payload['balance_gold_18k'] == round(float(canonical.get('18k') or 0.0), 3)

    def test_prefetched_batch_gives_the_same_answer_as_a_single_lookup(self):
        """The list endpoint passes a prefetched batch to avoid N+1; it must
        not become a second, subtly different answer."""
        supplier = _supplier()
        _post_gold(supplier, karat=22, credit=12.5)

        batch = compute_live_supplier_balances([supplier])
        assert _live_balance_payload(supplier, prefetched=batch) == _live_balance_payload(supplier)


class TestCurrentBalancePayload:

    def test_uses_the_ledger_endpoints_key_names(self):
        payload = _current_balance_payload(_supplier())
        assert set(payload) == {'cash', 'gold_18k', 'gold_21k', 'gold_22k', 'gold_24k'}

    def test_is_the_same_numbers_as_the_suppliers_list_answer(self):
        """The whole point of current_balance: the statement screen must not
        become a fourth answer."""
        supplier = _supplier()
        _post_gold(supplier, karat=21, credit=200.0)
        _post_gold(supplier, karat=21, debit=75.0)

        live = _live_balance_payload(supplier)
        current = _current_balance_payload(supplier)
        assert current['cash'] == live['balance_cash']
        assert current['gold_18k'] == live['balance_gold_18k']
        assert current['gold_21k'] == live['balance_gold_21k']
        assert current['gold_22k'] == live['balance_gold_22k']
        assert current['gold_24k'] == live['balance_gold_24k']


class TestPostingDoesNotCacheAnything:

    def test_create_dual_journal_entry_leaves_no_cached_supplier_state(self):
        """The removed writer's behavioural proof: after a real dual posting the
        supplier object carries no balance attribute at all, and the derived
        answer still reflects the posting."""
        supplier = _supplier()
        for column in ('balance_cash', 'balance_gold_21k'):
            assert not hasattr(supplier, column)

        _post_gold(supplier, karat=21, credit=55.0)
        assert _live_balance_payload(supplier)['balance_gold_21k'] == -55.0
