"""A pool's average is read from the ledger (ADR-042 phase 3, step 1).

The owner (21 Oct 2026): «اتفق مع توصياتك بجميع القرارات» -- the gold's value is
written when each document posts, at the average of that moment, and the
average is the ledger's: the pool's value is its financial stock account's
balance (1300 worked, 1310 scrap), its weight the weight on its safes. No table
of averages, no copy.

Which safe is in which pool is its stock location (ADR-045), one reader for the
stock: the showroom (and a piece at a workshop or in transit) is worked gold;
the scrap, an employee's custody and the gold deposited with an office are
scrap; the gold owed to the worked-gold suppliers counts out of the scrap, as
it is paid from it. A gold safe with no location is a party's, in neither.

The witness: the owner's worked example (test_gold_cost), posted as phase 3
will post it -- each movement with its value -- is read by the ledger reader
exactly as the replay computes it from the same movements.

Run:
    python -m pytest tests/test_gold_cost_pool_reader.py -v
"""
from datetime import date, datetime

import pytest

from models import COST_POOL_OF_LOCATION, STOCK_LOCATIONS, Account, SafeBox, db
from services.gold_cost import pool_accounts, pool_state, replay
from tests.test_gold_cost import _account, _child, _entry, _role_twin

JAN, FEB = datetime(2032, 1, 1), datetime(2032, 2, 1)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def test_every_stock_location_is_in_one_cost_pool():
    assert set(COST_POOL_OF_LOCATION) == set(STOCK_LOCATIONS)
    assert {k for k, v in COST_POOL_OF_LOCATION.items() if v == 'worked'} == {'showroom', 'workshop', 'transit'}
    assert {k for k, v in COST_POOL_OF_LOCATION.items() if v == 'scrap'} == {'scrap', 'custody', 'deposit'}


def _safe(location, tag):
    account = _child(_account('7139'), f'{tag} وزني')
    account.tracks_weight = True
    db.session.add(SafeBox(name=f'{tag} اختبار', safe_type='gold', account_id=account.id,
                           stock_location=location, is_active=True))
    db.session.flush()
    return account


@pytest.fixture
def books():
    from accounting.chart_tree import role_account_id
    return {
        'showroom': _safe('showroom', 'معروض'),
        'scrap': _safe('scrap', 'كسر'),
        'custody': _safe('custody', 'عهدة'),
        'deposit': _safe('deposit', 'وديعة مكتب'),
        'party_safe': _safe(None, 'خزنة طرف'),
        'supplier': _child(_role_twin('worked_gold_suppliers_root'), 'مورد اختبار وزني'),
        'customer': _child(_role_twin('customer_receivables_root'), 'عميل اختبار وزني'),
        'twin': _child(_account('7512'), 'مشتريات وزني اختبار'),
        'cash': _child(_account('1100'), 'صندوق اختبار'),
        'worked_value': db.session.get(Account, role_account_id('gold_inventory_new')),
        'scrap_value': db.session.get(Account, role_account_id('gold_inventory_scrap')),
        'cost_of_sales': _child(_account('521'), 'تكلفة مبيعات اختبار'),
    }


def test_the_pools_are_the_safes_by_their_location_and_the_suppliers_gold(books):
    pools = pool_accounts()
    assert books['showroom'].id in pools['worked']
    assert {books[k].id for k in ('scrap', 'custody', 'deposit', 'supplier')} <= pools['scrap']
    assert books['party_safe'].id not in pools['worked'] | pools['scrap']
    assert not pools['worked'] & pools['scrap']


def _delta(name):
    before, after = pool_state(name, until=JAN), pool_state(name, until=FEB)
    return after.weight - before.weight, after.value - before.value


def test_the_ledger_reads_the_worked_example_as_the_replay_computes_it(books):
    b = books
    _entry(1, [(b['scrap'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (b['scrap_value'], {'cash_debit': 40000}), (b['cash'], {'cash_credit': 40000})])     # bought
    _entry(2, [(b['deposit'], {'debit_21k': 50}), (b['twin'], {'credit_21k': 50}),
               (b['scrap_value'], {'cash_debit': 21500}), (b['cash'], {'cash_credit': 21500})])     # from an office
    _entry(3, [(b['showroom'], {'debit_21k': 120}), (b['supplier'], {'credit_21k': 120}),          # gold for gold,
               (b['worked_value'], {'cash_debit': 49200}), (b['scrap_value'], {'cash_credit': 49200})])  # at 410
    _entry(4, [(b['supplier'], {'debit_21k': 120}), (b['scrap'], {'credit_21k': 120})])            # paid in scrap
    _entry(5, [(b['showroom'], {'credit_21k': 80}), (b['customer'], {'debit_21k': 80}),            # sold, at
               (b['cost_of_sales'], {'cash_debit': 32800}), (b['worked_value'], {'cash_credit': 32800})])  # 410
    _entry(6, [(b['scrap'], {'debit_24k': 52.5}), (b['twin'], {'credit_24k': 52.5}),               # 60 g at the
               (b['scrap_value'], {'cash_debit': 27000}), (b['cash'], {'cash_credit': 27000})])     # main karat

    r = replay(opening_price=0.0, since=date(2032, 1, 1), until=date(2032, 2, 1))
    assert r.others == []
    for name in ('worked', 'scrap'):
        weight, value = _delta(name)
        assert weight == pytest.approx(r.pools[name].weight), name
        assert value == pytest.approx(r.pools[name].value), name
    assert _delta('worked') == (pytest.approx(40), pytest.approx(16400))
    assert _delta('scrap') == (pytest.approx(90), pytest.approx(39300))


def test_the_average_is_the_value_over_the_weight_and_none_on_an_empty_pool():
    from services.gold_cost import PoolState
    assert PoolState(weight=90, value=39300).average == pytest.approx(436.67, abs=0.01)
    assert PoolState(weight=-70, value=-28700).average == pytest.approx(410)    # a short pool keeps its average
    assert PoolState(weight=0.0001, value=12.0).average is None
