"""2026 opens on what the shop held, each debt on its owner (ADR-088).

The owner (11-12 Nov 2026): «الأصل أن نسجّل الذهب الموجود كما هو، والسحبيات
وغيرها تُسجَّل لكي تتطابق أوزان العيارات». The repair writes the plan's
entries from his figures (services/repair/opening_2026.json). The laws:
  - every entry is a posted correction, balanced column by column;
  - it writes nothing when the books are not as the plan found them, or when
    a number names another account than the plan's;
  - a protected account is touched only by the owner's leave, named in the
    figures (1720/71720, 12 Nov 2026) -- any other stays refused;
  - when the result is not the plan's it refuses (the caller rolls back);
  - the Riyadh partners' part splits by their shares, to the thousandth,
    summing exactly;
  - a second run writes nothing;
  - the owner's figures themselves balance, and name no tax account.

Run:
    python -m pytest tests/test_opening_2026_reorganization.py -v
"""
import copy
import datetime as dt
import uuid

import pytest

from app import app as flask_app
from models import Account, AccountingMapping, JournalEntry, JournalEntryLine, db
from services.repair.entries import ProtectedAccount
from services.repair.opening_2026 import COLUMNS, OpeningRefused, _split, load, reorganize

NOW = dt.datetime(2026, 11, 12, 10, 0)
SHARES = {'p1': '17/30', 'p2': '17/60', 'p3': '3/20'}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fence(app, db_fence):
    yield


def _account(name, *, weight, protected=False, parent=None):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name=name, type='Asset',
                transaction_type='gold' if weight else 'cash', tracks_weight=weight, repair_protected=protected,
                parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _post(number, lines):
    je = JournalEntry(entry_number=number, date=dt.datetime(2026, 1, 1), description='seed', entry_type='عادي',
                      is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='seed', **cols))
    db.session.flush()
    return je


@pytest.fixture
def world():
    """A small 2026: an opening booked short, a clearing account carrying a
    debt, gold parked in the dealings ledger, a shortage holding a payment."""
    tag = uuid.uuid4().hex[:6]
    a = {k: _account(f'{k} {tag}', weight=w, protected=p) for k, w, p in (
        ('display', True, False), ('temp', True, False), ('capital_w', True, False), ('capital_c', False, False),
        ('opening_adjust_w', True, False), ('clearing_c', False, True), ('clearing_w', True, True),
        ('dealings_w', True, False), ('shortage', False, False), ('creditors', False, False),
        ('p1', True, False), ('p2', True, False), ('p3', True, False))}
    root = _account(f'stock {tag}', weight=False)
    role = f'test_stock_root_{tag}'
    db.session.add(AccountingMapping(operation_type='افتراضي', account_type=role, account_id=root.id, is_active=True))
    opening = f'JE-T-{tag}'
    _post(opening, [(a['display'], {'debit_18k': 100.0}), (a['capital_w'], {'credit_18k': 100.0})])
    _post(f'JE-S-{tag}', [(a['clearing_c'], {'cash_credit': 500.0}), (a['clearing_w'], {'debit_21k': 5.0}),
                          (a['dealings_w'], {'debit_21k': 30.0}), (a['temp'], {'credit_21k': 10.0}),
                          (a['shortage'], {'cash_debit': 1000.0})])
    figures = {
        'reference_type': f'opening_test_{tag}', 'count_price': 440, 'opening_entry': opening,
        'count': {'18k': 120.0, '21k': 0.0},
        'accounts': {k: {'number': v.account_number, 'name': v.name} for k, v in a.items()},
        'made_account': {'key': 'earrings', 'name': f'earrings {tag}', 'parent_role': role},
        'protected_allowed': ['clearing_c', 'clearing_w'],
        'riyadh_shares': SHARES,
        'expect_before': {'dealings_w': {'21k': 30.0}, 'clearing_c': {'cash': -500.0}, 'clearing_w': {'21k': 5.0},
                          'temp': {'21k': -10.0}, 'shortage': {'cash': 1000.0}},
        'expect_opening_lines': {'display': {'18k': 100.0}},
        'entries': [
            {'key': 'T1', 'date': '2026-01-01', 'type': 'افتتاحي', 'description': 'الموجود',
             'lines': [{'account': 'display', 'dr': {'18k': 20.0}}, {'account': 'temp', 'dr': {'21k': 10.0}},
                       {'account': 'capital_w', 'cr': {'18k': 20.0, '21k': 10.0}}]},
            {'key': 'T2', 'date': '2026-01-01', 'type': 'افتتاحي', 'description': 'الوسيط',
             'lines': [{'account': 'clearing_w', 'cr': {'21k': 5.0}}, {'account': 'capital_w', 'dr': {'21k': 5.0}},
                       {'account': 'clearing_c', 'dr': {'cash': 500.0}}, {'account': 'capital_c', 'cr': {'cash': 500.0}}]},
            {'key': 'T3', 'date': '2026-01-01', 'type': 'افتتاحي', 'description': 'السحب',
             'lines': [{'account': 'capital_w', 'dr': {'21k': 30.0}}, {'account': 'riyadh', 'cr': {'21k': 30.0}}]},
            {'key': 'T4', 'date': '2026-01-10', 'type': 'تصحيح', 'description': 'سداد',
             'lines': [{'account': 'creditors', 'dr': {'cash': 400.0}}, {'account': 'shortage', 'cr': {'cash': 400.0}}]},
            {'key': 'T5', 'date': '2026-01-01', 'type': 'افتتاحي', 'description': 'الحلق',
             'lines': [{'account': 'earrings', 'dr': {'cash': 50.0}}, {'account': 'capital_c', 'cr': {'cash': 50.0}}]},
        ],
        'expect_after': {'clearing_c': {'cash': 0.0}, 'clearing_w': {'21k': 0.0}, 'temp': {'21k': 0.0},
                         'dealings_w': {'21k': 30.0}, 'shortage': {'cash': 600.0}},
        'expect_partners_main': {'p1': -17.0, 'p2': -8.5, 'p3': -4.5},
        # 100 and 20 of 18 (102.857) + 10 - 5 - 30 of 21, and 550 riyals at 440 (1.25)
        'expect_opening_main': 79.11,
    }
    return {'a': a, 'figures': figures, 'root': root}


def _ours(figures):
    return JournalEntry.query.filter_by(reference_type=figures['reference_type']).all()


def _sums(entry):
    out = {}
    for line in entry.lines:
        for col in COLUMNS:
            dr = f'cash_debit' if col == 'cash' else f'debit_{col}'
            cr = f'cash_credit' if col == 'cash' else f'credit_{col}'
            out[col] = out.get(col, 0.0) + float(getattr(line, dr) or 0) - float(getattr(line, cr) or 0)
    return out


def test_the_plan_is_written_balanced_and_lands_where_it_says(world):
    result = reorganize(by='t', now=NOW, figures=world['figures'])
    entries = _ours(world['figures'])
    assert len(entries) == 5 and len(result['entries']) == 5
    for e in entries:
        assert all(abs(v) < 0.0005 for v in _sums(e).values()), e.entry_number
        assert e.is_posted
    assert result['after']['partners_main'] == {'p1': -17.0, 'p2': -8.5, 'p3': -4.5}
    assert result['after']['opening_main'] == 79.11
    made = Account.query.filter_by(name=world['figures']['made_account']['name']).one()
    assert made.parent_id == world['root'].id and made.memo_account_id, 'under its role, with its weight twin'


def test_a_second_run_writes_nothing(world):
    reorganize(by='t', now=NOW, figures=world['figures'])
    again = reorganize(by='t', now=NOW, figures=world['figures'])
    assert again['already'] is True
    assert len(_ours(world['figures'])) == 5


def test_books_not_as_the_plan_found_them_write_nothing(world):
    _post(f'JE-X-{uuid.uuid4().hex[:6]}', [(world['a']['dealings_w'], {'debit_21k': 1.0})])
    with pytest.raises(OpeningRefused, match='dealings_w 21k'):
        reorganize(by='t', now=NOW, figures=world['figures'])
    assert _ours(world['figures']) == []


def test_a_number_naming_another_account_is_refused(world):
    figures = copy.deepcopy(world['figures'])
    figures['accounts']['shortage']['name'] = 'حساب آخر'
    with pytest.raises(OpeningRefused, match='shortage'):
        reorganize(by='t', now=NOW, figures=figures)
    assert _ours(figures) == []


def test_a_protected_account_needs_the_owners_leave(world):
    figures = copy.deepcopy(world['figures'])
    figures['protected_allowed'] = []
    with pytest.raises(ProtectedAccount):
        reorganize(by='t', now=NOW, figures=figures)


def test_a_result_other_than_the_plans_is_refused(world):
    figures = copy.deepcopy(world['figures'])
    figures['expect_after']['shortage']['cash'] = 599.0
    with pytest.raises(OpeningRefused, match='shortage'):
        reorganize(by='t', now=NOW, figures=figures)


def test_the_riyadh_part_splits_by_shares_summing_exactly():
    # 0.01 and 0.017: each part rounded to the thousandth, the parts miss the amount -- the remainder goes to the first
    for amount in (4388.0, 612.0, 2904.47, 188.5, 737.32, 561.6, 0.001, 0.01, 0.017):
        parts = _split(amount, SHARES)
        assert round(sum(parts.values()), 3) == round(amount, 3), amount
    assert _split(4388.0, SHARES) == {'p1': 2486.533, 'p2': 1243.267, 'p3': 658.2}


def test_the_owners_figures_balance_and_touch_no_tax_account():
    figures = load()
    known = set(figures['accounts']) | {'riyadh', figures['made_account']['key']}
    for entry in figures['entries']:
        assert dt.date.fromisoformat(entry['date']).year == 2026, entry['key']
        totals = {}
        for line in entry['lines']:
            assert line['account'] in known, (entry['key'], line['account'])
            for side, sign in (('dr', 1), ('cr', -1)):
                for col, amount in (line.get(side) or {}).items():
                    assert col in COLUMNS
                    totals[col] = totals.get(col, 0.0) + sign * float(amount)
        assert all(abs(v) < 0.0005 for v in totals.values()), (entry['key'], totals)
    assert not [k for k, v in figures['accounts'].items() if 'ضريب' in v['name']]
    assert set(figures['protected_allowed']) == {'gold_clearing_c', 'gold_clearing_w'}
