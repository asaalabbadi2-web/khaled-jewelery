"""The inventory screens read the one reader (ADR-045 C2).

«الجرد الفعلي» showed the old ledger's buckets by branch; «مركز التدقيق»
matched four sources (that ledger, its cached balance, the count, the books).
The stock is the books now (A1): the balance is per location (the stock safes),
and the audit shows what can still be wrong -- an allocation against its line
(the nightly STOCK_ALLOCATION_INVALID), open count sessions, each location's
last approved count, and how much is still «بلا تصنيف».

Run:
    python -m pytest tests/test_stock_screens.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Category, JournalEntry, JournalEntryLine, SafeBox, db

NOW = datetime(2026, 10, 13, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:8]


def _safe(location='showroom'):
    account = Account(account_number=f'9{_uid()[:6]}', name=f'ح {_uid()}', type='Asset', tracks_weight=True)
    db.session.add(account)
    db.session.flush()
    box = SafeBox(name=f'خزينة {_uid()}', safe_type='gold', account_id=account.id, is_active=True,
                  stock_location=location)
    db.session.add(box)
    db.session.flush()
    return box


def _stock(box, grams, category=None, karat=21):
    from services.stock_ledger import allocate
    je = JournalEntry(entry_number=f'JE-V-{_uid()}', date=NOW, description='رصيد', entry_type='عادي',
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, description='رصيد',
                            **{f'debit_{karat}k': grams})
    db.session.add(line)
    db.session.flush()
    if category is not None:
        allocate(line, karat, category.id, grams, by='t', now=NOW)
    return line


def _get(url, headers):
    resp = flask_app.test_client().get(url, headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_the_balance_is_per_location_category_and_karat(app, auth_headers):
    box = _safe()
    ring = Category(name=f'خاتم {_uid()}', karat='21')
    db.session.add(ring)
    db.session.flush()
    _stock(box, 20.0, ring)
    _stock(box, 5.0)
    rows = _get(f'/api/inventory/balance?safe_box_id={box.id}', auth_headers)
    got = {(r['category_id'], r['karat']): (r['balance'], r['category_name']) for r in rows}
    assert got == {(ring.id, 21.0): (20.0, ring.name), (None, 21.0): (5.0, 'بلا تصنيف')}
    assert {(r['safe_box_id'], r['safe_box_name'], r['stock_location']) for r in rows} == {(box.id, box.name, 'showroom')}


def test_the_summary_is_by_location_and_by_karat(app, auth_headers):
    box = _safe('custody')
    _stock(box, 18.0, karat=18)
    summary = _get('/api/inventory/balance/summary', auth_headers)
    mine = [l for l in summary['by_location'] if l['safe_box_id'] == box.id]
    assert mine and mine[0]['stock_location'] == 'custody'
    assert mine[0]['total_weight'] == pytest.approx(18.0 * 18 / 21, abs=0.01), 'at the main karat'
    assert {'karat', 'total_weight'} <= set(summary['by_karat'][0])
    assert 'unclassified_weight' in summary and 'grand_total_weight' in summary


def test_the_audit_reports_an_allocation_against_its_line(app, auth_headers):
    box = _safe()
    ring = Category(name=f'خاتم {_uid()}', karat='21')
    db.session.add(ring)
    db.session.flush()
    line = _stock(box, 20.0, ring)
    line.debit_21k = 10.0                       # edited after its allocation
    db.session.flush()
    health = _get('/api/inventory/health', auth_headers)
    metric = {m['key']: m for m in health['metrics']}['allocation_violations']
    assert metric['ok'] is False and metric['value'] >= 1 and health['has_issues'] is True


def test_the_audit_rows_are_the_books_per_location_and_karat(app, auth_headers):
    box = _safe()
    ring = Category(name=f'خاتم {_uid()}', karat='21')
    db.session.add(ring)
    db.session.flush()
    _stock(box, 20.0, ring)
    _stock(box, 5.0)
    report = _get('/api/inventory/reconciliation', auth_headers)
    row = [r for r in report['rows'] if r['safe_box_id'] == box.id and r['karat'] == 21.0][0]
    assert (row['books_grams'], row['classified_grams'], row['unclassified_grams']) == (25.0, 20.0, 5.0)
    assert row['last_count_at'] is None


def test_a_session_in_a_list_names_its_location_and_counts_its_lines(app, auth_headers):
    """The banner of «الجرد الفعلي» read a summary without lines -- it showed
    «الفرع» and 0 / 0 -- and only open sessions, never one awaiting approval."""
    from services.inventory_count_service import InventoryCountService as S
    box = _safe()
    _stock(box, 5.0)
    _stock(box, 2.0, karat=18)
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    S.record_count(session, category_id=None, karat=21.0, counted_weight=5.0, now=NOW)
    S.close_session(session, force=True, now=NOW)
    rows = _get('/api/inventory/count?status=closed', auth_headers)
    mine = [r for r in rows if r['id'] == session.id][0]
    assert (mine['safe_box_name'], mine['lines_total'], mine['lines_counted']) == (box.name, 2, 1)


def test_the_last_approved_count_says_when_and_who(app, auth_headers):
    """«آخر جرد معتمد» showed an empty line after a count was approved."""
    from services.inventory_count_service import InventoryCountService as S

    box = _safe()
    _stock(box, 5.0)
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    S.record_count(session, category_id=None, karat=21.0, counted_weight=5.0, now=NOW)
    S.close_session(session, force=True, now=NOW)
    S.approve_session(session, approved_by='المدير', now=datetime(2030, 1, 2, 9, 30))
    metric = {m['key']: m for m in _get('/api/inventory/health', auth_headers)['metrics']}['last_approved_count']
    assert metric['detail'] == '2030-01-02 09:30 — اعتمده المدير'
