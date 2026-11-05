"""The stock by location and karat -- one reader for the stock screen (INV-1, ADR-086).

The owner, 6 Nov 2026: the balance by «الموقع والعيار»; the audit «داخل شاشة
الأرصدة». Each stock safe is a location: its karats from the books, its total
at the main karat (three places, not four), its last approved count -- when,
who, the difference entry -- and the session open on it.

A location's categories are balances only once an approved count has
classified it: before, the stock opened «بلا تصنيف» and the sales since A1 took
their gold out of their categories, so a category's sum is its movement, not
what it holds («بنجرة ذهب 21» −480.59 g on the 5 Nov copy). The deposits with
the offices are a section of their own, not counted (ADR-052); the employees'
custody another. A location below zero in a karat says so. The nightly
check's allocations against their lines are counted.

Run:
    python -m pytest tests/test_stock_locations.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Category, db
from tests.test_stock_count import roles  # noqa: F401 (fixture)
from tests.test_stock_screens import _get, _safe, _stock

NOW = datetime(2026, 11, 6, 12, 0)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _category():
    c = Category(name=f'بنجرة {uuid.uuid4().hex[:6]}', karat='21')
    db.session.add(c)
    db.session.flush()
    return c


def _locations():
    from services.stock_ledger import stock_locations
    out = stock_locations(now=NOW)
    return out, {l['safe_box_id']: (s['key'], l) for s in out['sections'] for l in s['locations']}


def test_a_location_is_its_karats_and_its_total_at_the_main_karat():
    box = _safe()
    _stock(box, 10.0, karat=21)
    _stock(box, 7.0004, karat=18)
    out, by_id = _locations()
    section, loc = by_id[box.id]
    assert section == 'stock'
    assert {k['karat']: k['grams'] for k in loc['karats']} == {18: 7.0, 21: 10.0}
    assert loc['total_main'] == pytest.approx(10.0 + 7.0 * 18 / 21, abs=0.001)
    assert loc['total_main'] == round(loc['total_main'], 3), 'three places, not four'


def test_before_its_first_count_a_location_s_categories_are_its_movements():
    box = _safe()
    bangle = _category()
    _stock(box, 100.0)                      # the opening: «بلا تصنيف»
    _stock(box, -40.0, bangle)              # a sale out of its category
    _, by_id = _locations()
    loc = by_id[box.id][1]
    assert loc['categories_are_balances'] is False and loc['last_count'] is None
    assert [(c['category_id'], c['grams']) for c in loc['categories']] == [(bangle.id, -40.0)], \
        'its movement; «بلا تصنيف» is no category'


def test_once_counted_its_categories_are_balances_and_the_count_says_when_who_and_its_entry(roles):
    from services.inventory_count_service import InventoryCountService as S
    box = _safe()
    bangle = _category()
    _stock(box, 60.0)
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    S.record_count(session, category_id=bangle.id, karat=21.0, counted_weight=60.0, now=NOW)
    S.record_count(session, category_id=None, karat=21.0, counted_weight=0.0, now=NOW)
    S.close_session(session, force=True, now=NOW)
    S.approve_session(session, approved_by='المدير', now=NOW)
    _, by_id = _locations()
    loc = by_id[box.id][1]
    assert loc['categories_are_balances'] is True
    assert [(c['category_id'], c['grams']) for c in loc['categories']] == [(bangle.id, 60.0)]
    assert (loc['last_count']['session_id'], loc['last_count']['approved_by']) == (session.id, 'المدير')
    assert loc['last_count']['entry_number'], 'its difference entry'


def test_a_session_open_on_a_location_is_said_on_it():
    from services.inventory_count_service import InventoryCountService as S
    box = _safe()
    _stock(box, 5.0)
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    _, by_id = _locations()
    assert by_id[box.id][1]['open_session'] == {'id': session.id, 'status': 'open'}


def test_the_deposits_and_the_custody_are_sections_of_their_own_and_deposits_are_not_counted():
    deposit, custody = _safe('deposit'), _safe('custody')
    _stock(deposit, 3.0)
    _stock(custody, 2.0)
    out, by_id = _locations()
    assert (by_id[deposit.id][0], by_id[custody.id][0]) == ('deposit', 'custody')
    counted = {s['key']: s['counted'] for s in out['sections']}
    assert counted['deposit'] is False and counted['custody'] is True


def test_a_location_below_zero_says_so():
    box = _safe('scrap')
    _stock(box, -8.0)
    _, by_id = _locations()
    assert by_id[box.id][1]['negative'] is True


def test_the_screen_reads_one_route_and_the_old_four_are_gone(auth_headers):
    box = _safe()
    _stock(box, 4.0)
    out = _get('/api/inventory/locations', auth_headers)
    assert any(l['safe_box_id'] == box.id for s in out['sections'] for l in s['locations'])
    assert 'violations' in out and 'grand_total_main' in out
    client = flask_app.test_client()
    for gone in ('/api/inventory/balance/summary', '/api/inventory/reconciliation', '/api/inventory/health',
                 '/api/inventory/balance'):
        assert client.get(gone, headers=auth_headers).status_code == 404, gone
