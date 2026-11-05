"""The closing count of 31 December, a session per location (INV-2, ADR-086).

The owner, 6 Nov 2026: «جلسة لكل موقع»; the counter sees no expected weight
(«عدّ أعمى») -- a category's expected is meaningless before the stock is
classified, the karat's total in the location is what means; the lines are
listed «حسب نوع الموقع»: the showroom the active worked categories, a scrap
store the active scrap ones, a custody what it holds -- never a stopped
category. A count is of one location: none for every one at once, and none on
a location an older all-locations session still holds. Weights at two places
(ADR-085). Once closed, the review says per karat the books, the counted and
the difference -- the entry is per (location, karat). The stock screen says
each open count's progress.

Run:
    python -m pytest tests/test_closing_count.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Category, InventoryCountSession, db
from tests.test_stock_count import roles  # noqa: F401 (fixture)
from tests.test_stock_screens import _get, _safe, _stock

NOW = datetime(2026, 12, 31, 18, 0)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _category(name, *, scrap=False, active=True, karat='21'):
    c = Category(name=f'{name} {uuid.uuid4().hex[:6]}', karat=karat, is_scrap=scrap, is_active=active)
    db.session.add(c)
    db.session.flush()
    return c


def _open_full(box):
    from services.inventory_count_service import InventoryCountService as S
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW, session_type='opening')
    S.populate_opening_lines(session)
    return session


def test_a_count_is_of_one_location():
    from services.inventory_count_service import InventoryCountService as S
    with pytest.raises(ValueError, match='موقع واحد'):
        S.open_session(branch_id=None, safe_box_id=None, opened_by='t', now=NOW)


def test_no_count_on_a_location_an_older_all_locations_session_holds():
    from services.inventory_count_service import InventoryCountService as S
    box = _safe()
    db.session.add(InventoryCountSession(status='open', session_type='opening', opened_by='t', opened_at=NOW))
    db.session.flush()
    with pytest.raises(ValueError, match='كل المواقع'):
        S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)


def test_the_showroom_lists_its_active_worked_categories_never_a_stopped_one_nor_scrap():
    showroom = _safe('showroom')
    bangle, stopped, scrap = _category('بنجرة'), _category('موقوف', active=False), _category('كسر', scrap=True)
    session = _open_full(showroom)
    listed = {l.category_id for l in session.lines}
    assert bangle.id in listed and stopped.id not in listed and scrap.id not in listed


def test_a_scrap_store_lists_its_active_scrap_categories():
    store = _safe('scrap')
    bangle, scrap = _category('بنجرة'), _category('كسر', scrap=True)
    session = _open_full(store)
    listed = {l.category_id for l in session.lines}
    assert scrap.id in listed and bangle.id not in listed


def test_a_custody_lists_what_it_holds():
    custody = _safe('custody')
    _category('بنجرة')
    _stock(custody, 3.0)
    session = _open_full(custody)
    assert {(l.category_id, l.karat) for l in session.lines} == {(None, 21.0)}


def test_the_full_count_is_blind_and_its_review_is_per_karat(auth_headers):
    from services.inventory_count_service import InventoryCountService as S
    box = _safe()
    _stock(box, 100.0)
    _stock(box, 20.0, karat=18)
    session = _open_full(box)
    assert session.blind_count is True
    detail = _get(f'/api/inventory/count/{session.id}', auth_headers)
    assert all(l['expected_weight'] is None for l in detail['lines'])
    assert detail.get('by_karat') is None, 'nothing to compare while counting'

    S.record_count(session, category_id=None, karat=21.0, counted_weight=98.5, now=NOW)
    S.record_count(session, category_id=None, karat=18.0, counted_weight=20.0, now=NOW)
    S.close_session(session, zero_uncounted=True, now=NOW)
    detail = _get(f'/api/inventory/count/{session.id}', auth_headers)
    by = {r['karat']: (r['books'], r['counted'], r['difference']) for r in detail['by_karat']}
    assert by == {18.0: (20.0, 20.0, 0.0), 21.0: (100.0, 98.5, -1.5)}


def test_a_weight_is_at_two_places_and_not_below_zero():
    from services.inventory_count_service import InventoryCountService as S
    box = _safe()
    _stock(box, 5.0)
    session = _open_full(box)
    with pytest.raises(ValueError, match='خانتين'):
        S.record_count(session, category_id=None, karat=21.0, counted_weight=4.555, now=NOW)
    with pytest.raises(ValueError, match='سالب'):
        S.record_count(session, category_id=None, karat=21.0, counted_weight=-1.0, now=NOW)
    assert S.record_count(session, category_id=None, karat=21.0, counted_weight=4.55, now=NOW).counted_weight == 4.55


def test_the_stock_screen_says_each_open_count_s_progress():
    from services.inventory_count_service import InventoryCountService as S
    from services.stock_ledger import stock_locations
    box = _safe()
    _stock(box, 5.0)
    _stock(box, 2.0, karat=18)
    session = _open_full(box)
    S.record_count(session, category_id=None, karat=21.0, counted_weight=5.0, now=NOW)
    loc = {l['safe_box_id']: l for s in stock_locations(now=NOW)['sections'] for l in s['locations']}[box.id]
    assert loc['open_session']['id'] == session.id
    assert (loc['open_session']['lines_counted'], loc['open_session']['lines_total']) == (1, session.lines.count())


def test_the_open_route_refuses_every_location_at_once(auth_headers):
    resp = flask_app.test_client().post('/api/inventory/count', headers=auth_headers,
                                        json={'session_type': 'opening'})
    assert resp.status_code == 400 and 'موقع واحد' in resp.get_json()['error']
