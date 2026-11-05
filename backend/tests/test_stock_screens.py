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


def test_the_audit_reports_an_allocation_against_its_line(app, auth_headers):
    box = _safe()
    ring = Category(name=f'خاتم {_uid()}', karat='21')
    db.session.add(ring)
    db.session.flush()
    line = _stock(box, 20.0, ring)
    line.debit_21k = 10.0                       # edited after its allocation
    db.session.flush()
    # the audit sits in the stock screen now (INV-1, ADR-086)
    assert _get('/api/inventory/locations', auth_headers)['violations'] >= 1


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


