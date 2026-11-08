"""A location's «بلا تصنيف» below zero is reported every night (the owner, 8 Nov 2026).

Gold that leaves a stock location without its category -- a transfer, a
gold payment voucher («سحب»), a manual entry -- leaves the category behind
as if held, and the location's unclassified rest goes negative: Mubarak's
custody on the 5 Nov copy, «كسر 21» +243.93 and «بلا تصنيف» −243.93. The
books are right by the karat; the split by category is wrong there until the
count. The check says it on the day it happens, not on the count's: it
reports, it does not repair (ADR-030). Keyed 'safe_box:<id>:<k>k', the
metric the negative grams.

Run:
    python -m pytest tests/test_stock_unclassified_negative.py -v
"""
from services.books_invariants import CHECKS, STOCK_UNCLASSIFIED_NEGATIVE
from tests.test_count_negative_line import _moved_out
from tests.test_stock_count import _category, _safe, _stock
from tests.test_stock_count import app, rollback_after_each  # noqa: F401 -- the module's fixtures


def _facts(box):
    return [f for f in CHECKS[STOCK_UNCLASSIFIED_NEGATIVE]() if f.subject_key.startswith(f'safe_box:{box.id}:')]


def test_a_category_left_behind_is_reported(app):
    box = _safe('custody')
    _stock(box, 20.0, _category())
    _moved_out(box, 20.0)
    facts = _facts(box)
    assert [(f.subject_key, f.metric) for f in facts] == [(f'safe_box:{box.id}:21k', -20.0)]
    assert facts[0].detail['karat'] == 21 and facts[0].detail['safe_box_name'] == box.name
    assert facts[0].detail['karat_total_grams'] == 0.0, 'the karat is right: a category left behind'


def test_a_karat_itself_below_zero_says_so(app):
    box = _safe('scrap')
    _moved_out(box, 8.0)
    assert [f.detail['karat_total_grams'] for f in _facts(box)] == [-8.0]


def test_a_location_whose_split_holds_is_not(app):
    box = _safe('custody')
    _stock(box, 20.0, _category())
    _stock(box, 5.0)               # unclassified, positive
    _moved_out(box, 5.0)           # out of the unclassified: zero, not below
    assert _facts(box) == []


def test_the_kind_says_what_it_means():
    from services.finding_kinds import KIND_INFO, subject_label
    info = KIND_INFO[STOCK_UNCLASSIFIED_NEGATIVE]
    assert info['title_ar'] and info['explanation_ar']
    assert subject_label('safe_box:30:21k').endswith('عيار 21')
