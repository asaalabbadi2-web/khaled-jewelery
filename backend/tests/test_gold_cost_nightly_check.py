"""The gold's cost, checked every night against its replay (ADR-042 phase 3, step 7).

The owner (21 Oct 2026): «اتفق مع توصياتك بجميع القرارات» -- the value is
written when each document posts, and the replay stays as the nightly witness.
From the settings' day (gold_cost_from), the nightly check (ADR-030: it
reports, never repairs) says:

  GOLD_COST_DRIFT        a pool's value in the books since the day is not the
                         replay's of the same movements -- a writer valued at
                         another average, or not at all;
  GOLD_MOVED_UNVALUED    an entry moved a pool's gold and wrote no value -- a
                         path no writer values (a manual entry, a new writer);
  GOLD_WITH_PARTY_ADRIFT a party's grams in the books are not the grams its
                         value was written for -- gold passed from party to
                         party without a pool, its value left with the first.
With no day set, it says nothing: 2026 posts as it always has.

Run:
    python -m pytest tests/test_gold_cost_nightly_check.py -v
"""
from datetime import date

import pytest

from accounting.chart_tree import role_account_id
from models import Account, AccountingMapping, Settings, db
from services.books_invariants import (CHECKS, GOLD_COST_DRIFT, GOLD_MOVED_UNVALUED, GOLD_WITH_PARTY_ADRIFT,
                                       KINDS)
from tests.test_gold_cost import _account as _tree_account
from tests.test_gold_cost import _child, _entry
from tests.test_gold_moves_with_its_value import _party_and_role, _weight_child, roles  # noqa: F401 (fixture)
from tests.test_melting_and_renewal_go_one_way import _safe

DAY = date(2032, 1, 1)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _from(day):
    Settings.query.first().gold_cost_from = day
    db.session.flush()


def _facts(kind):
    return {f.subject_key: f for f in CHECKS[kind]()}


@pytest.fixture
def books(roles):
    """2032, alone: 20 g of scrap bought at 400 (8,000), 100 g of worked at 500
    (50,000)."""
    b = {'scrap': _safe('scrap'), 'showroom': _safe('showroom'),
         'twin': _child(_tree_account('7512'), 'مشتريات وزني NC'), 'cash': _child(_tree_account('1100'), 'صندوق NC'),
         'customer': _child(_tree_account('7139'), 'مقابل NC'),
         'cost': _child(_tree_account('521'), 'تكلفة مبيعات NC')}
    b['scr'], b['show'] = db.session.get(Account, b['scrap'].account_id), db.session.get(Account, b['showroom'].account_id)
    b['sv'], b['wv'] = (db.session.get(Account, role_account_id('gold_inventory_scrap')),
                        db.session.get(Account, role_account_id('gold_inventory_new')))
    _entry(1, [(b['scr'], {'debit_21k': 20}), (b['twin'], {'credit_21k': 20}),
               (b['sv'], {'cash_debit': 8000}), (b['cash'], {'cash_credit': 8000})])
    _entry(1, [(b['show'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (b['wv'], {'cash_debit': 50000}), (b['cash'], {'cash_credit': 50000})])
    return b


def test_the_three_checks_are_the_nights():
    assert {GOLD_COST_DRIFT, GOLD_MOVED_UNVALUED, GOLD_WITH_PARTY_ADRIFT} <= set(KINDS) & set(CHECKS)


def test_with_no_day_set_they_say_nothing(books):
    _from(None)
    expense = _weight_child('operating_expenses_root', 'مصروف وزني NC')
    _entry(2, [(books['scr'], {'credit_21k': 5}), (expense, {'debit_21k': 5})])     # unvalued
    for kind in (GOLD_COST_DRIFT, GOLD_MOVED_UNVALUED, GOLD_WITH_PARTY_ADRIFT):
        assert _facts(kind) == {}


def test_books_written_at_their_averages_say_nothing(books):
    _from(DAY)
    _entry(2, [(books['show'], {'credit_21k': 10}), (books['customer'], {'debit_21k': 10}),
               (books['cost'], {'cash_debit': 5000}), (books['wv'], {'cash_credit': 5000})])       # sold at 500
    assert _facts(GOLD_COST_DRIFT) == {}
    assert _facts(GOLD_MOVED_UNVALUED) == {}


def test_a_sale_costed_at_another_average_is_a_drift_of_its_pool(books):
    _from(DAY)
    _entry(2, [(books['show'], {'credit_21k': 10}), (books['customer'], {'debit_21k': 10}),
               (books['cost'], {'cash_debit': 4000}), (books['wv'], {'cash_credit': 4000})])       # 400, not 500
    facts = _facts(GOLD_COST_DRIFT)
    assert set(facts) == {'gold_pool:worked'}
    assert facts['gold_pool:worked'].metric == pytest.approx(1000.0), 'the books hold 1,000 more than the replay'


def test_gold_moved_with_no_value_is_named_by_its_entry(books):
    _from(DAY)
    expense = _weight_child('operating_expenses_root', 'مصروف وزني NC')
    _entry(2, [(books['scr'], {'credit_21k': 5}), (expense, {'debit_21k': 5})])       # a manual entry: no value
    facts = _facts(GOLD_MOVED_UNVALUED)
    assert len(facts) == 1
    (key, fact), = facts.items()
    assert key.startswith('journal_entry:') and fact.metric == pytest.approx(-5.0)
    assert 'gold_pool:scrap' in _facts(GOLD_COST_DRIFT), 'and its pool drifts from the replay by its value'


def test_gold_passed_from_party_to_party_is_a_party_adrift(books):
    _from(DAY)
    employee = _party_and_role()
    other = _weight_child('assets_root', 'موظف آخر وزني NC')
    with_parties = db.session.get(Account, AccountingMapping.query.filter_by(account_type='gold_with_parties')
                                  .one().account_id)
    _entry(2, [(books['scr'], {'credit_21k': 5}), (employee, {'debit_21k': 5}),
               (with_parties, {'cash_debit': 2000}), (books['sv'], {'cash_credit': 2000})])    # out at 400
    assert _facts(GOLD_WITH_PARTY_ADRIFT) == {}
    _entry(3, [(employee, {'credit_21k': 2}), (other, {'debit_21k': 2})])               # party to party
    facts = _facts(GOLD_WITH_PARTY_ADRIFT)
    assert set(facts) == {f'account:{employee.id}'}
    assert facts[f'account:{employee.id}'].metric == pytest.approx(-2.0), 'its books hold 2 g fewer than its value'


def test_the_screen_names_a_pool_and_a_party():
    from services.finding_kinds import subject_label
    assert subject_label('gold_pool:worked') == 'مخزن المشغول'
    assert subject_label('gold_pool:scrap') == 'مخزن الكسر'
    assert subject_label('account:12') == 'حساب رقم 12'
