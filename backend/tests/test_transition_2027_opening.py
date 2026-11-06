"""2027's opening entries from 2026's closing (ADR-044 decision 2, TR-4c).

The owner, 7 Nov 2026: the differences in 2026 at the close (TR-4a, TR-4b),
so 2027 opens on 2026's closing as it is -- ADR-044's law: «مجموع الأرصدة
الافتتاحية = ميزان الإقفال بعد قيود الجرد، بالهللة وبالجرام». Each account
with a balance is placed: an income or expense, and an equity account the
2027 chart left out (370), close into retained earnings (32, its weight
twin 732); one in the template, or carried with the master data (a party's,
a custody's, a deposit's), opens on its 2027 account; a customer's gold
mirror (CUSTGOLD-001) or an asset or liability with no place is refused by
name. One entry a group, each balanced in riyals and karat by karat against
32 / 732. The whole build runs on an empty database in its rehearsal
(docs/plans/fy2027-transition-tool-discovery.md).

Run:
    python -m pytest tests/test_transition_2027_opening.py -v
"""
from collections import namedtuple

import pytest

from services.transition_2027 import CARRY, FOLD, MIRROR, REFUSE, TransitionRefused, place, plan_opening

Row = namedtuple('Row', 'id account_number name type tracks_weight')
SRC = {
    1: Row(1, '1100', 'الصندوق', 'Asset', False),
    2: Row(2, '71100', 'الصندوق وزني', 'Asset', True),
    3: Row(3, '2100005', 'مورد', 'Liability', False),
    4: Row(4, '72100005', 'مورد وزني', 'Liability', True),
    5: Row(5, '410', 'المبيعات', 'Revenue', False),
    6: Row(6, '7410', 'المبيعات وزني', 'Revenue', True),
    7: Row(7, '370', 'عجز/فائض الخزائن', 'Equity', False),
    8: Row(8, '310', 'رأس المال', 'Equity', False),
    9: Row(9, '712001', 'ذهب عميل', 'Asset', True),
    10: Row(10, '1730001', 'حساب متروك', 'Asset', False),
    11: Row(11, '32', 'أرباح/خسائر محتجزة', 'Equity', False),
}
TEMPLATE = {'1100', '71100', '410', '7410', '310', '32'}
CARRIED = {3, 4, 9}
MIRRORS = {9}
NEW = {1: 101, 2: 102, 3: 103, 4: 104, 8: 108, 11: 132}
RETAINED = (132, 1732)
SECTION = {101: 'النقدية', 102: 'النقدية', 103: 'الموردون', 104: 'الموردون', 108: 'حقوق الملكية'}


def _place(i):
    return place(SRC[i], template=TEMPLATE, carried=CARRIED, mirrors=MIRRORS)


def test_each_account_is_placed():
    assert [_place(i) for i in (1, 2, 3, 4)] == [CARRY] * 4
    assert (_place(5), _place(6)) == (FOLD, FOLD), 'income closes into 32'
    assert _place(7) == FOLD, 'an equity account 2027 left out (370) closes into 32'
    assert _place(8) == CARRY
    assert _place(9) == MIRROR, "a customer's gold mirror does not enter 2027 (CUSTGOLD-001)"
    assert _place(10) == REFUSE, 'an asset with no place'


def _plan(balances):
    return plan_opening(balances, SRC, template=TEMPLATE, carried=CARRIED, mirrors=MIRRORS,
                        target=NEW.__getitem__, retained=RETAINED, section_of=SECTION.__getitem__)


def _zero(**kw):
    return {'cash': 0.0, '18': 0.0, '21': 0.0, '22': 0.0, '24': 0.0, **kw}


BOOKS = {
    1: _zero(cash=5000.0), 2: _zero(**{'21': 3.0}),
    3: _zero(cash=-1200.0), 4: _zero(**{'24': -10.0}),
    5: _zero(cash=-9000.0), 6: _zero(**{'21': -3.0, '24': 10.0}),
    7: _zero(cash=150.0), 8: _zero(cash=-100.0), 11: _zero(cash=5150.0),
}


def test_each_group_opens_on_its_closing_balanced_against_32():
    plan = _plan(BOOKS)
    entries = {e['section']: e for e in plan['entries']}
    assert set(entries) == {'النقدية', 'الموردون', 'حقوق الملكية'}
    cash = {l['account_id']: l for l in entries['النقدية']['lines']}
    assert cash[101]['cash'] == 5000.0 and cash[102]['21'] == 3.0
    assert cash[132]['cash'] == -5000.0 and cash[1732]['21'] == -3.0, 'the group balanced on 32 / 732'
    for e in plan['entries']:
        for col in ('cash', '18', '21', '22', '24'):
            assert round(sum(l.get(col, 0.0) for l in e['lines']), 6) == 0, (e['section'], col)


def test_32_takes_what_closes_into_it_and_the_opening_equals_the_closing():
    plan = _plan(BOOKS)
    opened = plan['opened']
    for old, new in ((1, 101), (2, 102), (3, 103), (4, 104), (8, 108)):
        assert opened[new] == {k: v for k, v in BOOKS[old].items() if v}, new
    # income (-9000), 370 (+150), 32's own (+5150): -3700 into 32
    assert plan['retained']['cash'] == pytest.approx(-3700.0)
    assert opened[132]['cash'] == pytest.approx(-3700.0)
    assert plan['karat_imbalance'] == {}, 'these books balance karat by karat'


def test_an_account_with_no_place_or_a_customer_s_gold_refuses_by_name():
    with pytest.raises(TransitionRefused, match='1730001'):
        _plan({**BOOKS, 10: _zero(cash=50.0)})
    with pytest.raises(TransitionRefused, match='712001'):
        _plan({**BOOKS, 9: _zero(**{'21': 2.0})})


def test_books_not_balanced_karat_by_karat_are_said_not_hidden():
    """2026's books balance in the main karat, not karat by karat (22 Oct
    2026): 732 takes each karat's rest, and the plan says it."""
    books = {**BOOKS, 2: _zero(**{'21': 3.0, '18': 1.0})}
    plan = _plan(books)
    assert plan['karat_imbalance'] == {'18': 1.0}


def test_a_group_balances_to_the_milligram_after_its_lines_are_rounded():
    """The books carry a few grams at four places; each line opens at three:
    732 takes the rest of the rounded lines, not of the books -- else the
    entry's main-karat weight is out by a thousandth (ENTRY_WEIGHT_UNBALANCED
    on the 5 Nov rehearsal, the suppliers' group)."""
    books = {**BOOKS, 4: _zero(**{'24': -10.0006}), 12: _zero(**{'24': -5.0006})}   # each rounds to -.001
    src = {**SRC, 12: Row(12, '72100006', 'مورد آخر وزني', 'Liability', True)}
    plan = plan_opening(books, src, template=TEMPLATE, carried=CARRIED | {12}, mirrors=MIRRORS,
                        target={**NEW, 12: 105}.__getitem__, retained=RETAINED,
                        section_of={**SECTION, 105: 'الموردون'}.__getitem__)
    for e in plan['entries']:
        for col in ('18', '21', '22', '24'):
            assert sum(l.get(col, 0.0) for l in e['lines']) == pytest.approx(0.0, abs=1e-9), (e['section'], col)
