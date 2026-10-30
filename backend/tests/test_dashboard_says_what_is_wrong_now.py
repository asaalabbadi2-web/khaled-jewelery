"""The manager's dashboard says what is wrong now (DASH-7).

The owner, 30 Oct 2026, agreeing to all advised: the nightly check's findings
reached only «نتائج الفحص الليلي», and a safe below zero was said nowhere.
Now both -- and only what is news: an accepted finding is true and known, a
retired kind's rows are history (INVENTORY_LEDGER_DRIFT's four open rows on
the production copy, from the check ADR-045 C3 retired), and a karat below zero
in a safe whose gold is above it is the drift checks', not a safe below zero.

Run:
    python -m pytest tests/test_dashboard_says_what_is_wrong_now.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import ReconciliationFinding, db
from services.dashboard_alerts import alerts


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _wrong_now(app, headers):
    return app.test_client().get('/api/dashboard/admin/standing', headers=headers).get_json()['wrong_now']


def _count(wrong, kind):
    return next((k['count'] for k in wrong['findings'] if k['kind'] == kind), 0)


def _finding(kind, **kw):
    db.session.add(ReconciliationFinding(kind=kind, source='books_invariants', subject_key=f'x:{uuid.uuid4().hex[:8]}',
                                         metric=1.0, created_at=datetime.utcnow(), **kw))
    db.session.flush()


def test_only_the_open_news_is_said(app, auth_headers):
    before = _wrong_now(app, auth_headers)
    _finding('ORPHAN_POSTED_ENTRY')                                             # news
    _finding('ORPHAN_POSTED_ENTRY', accepted_at=datetime.utcnow(), accepted_by='المالك',
             accepted_reason='حقيقي')                                           # known
    _finding('INVENTORY_LEDGER_DRIFT')                                          # retired: history
    after = _wrong_now(app, auth_headers)

    assert _count(after, 'ORPHAN_POSTED_ENTRY') - _count(before, 'ORPHAN_POSTED_ENTRY') == 1
    assert _count(after, 'INVENTORY_LEDGER_DRIFT') == 0
    title = next(k['title'] for k in after['findings'] if k['kind'] == 'ORPHAN_POSTED_ENTRY')
    assert title != 'ORPHAN_POSTED_ENTRY', 'the kind is said by its name, not its code'


def test_a_safe_below_zero_is_said_and_a_karat_below_zero_is_not(app):
    rows = [
        {'name': 'صندوق', 'balance_cash': -250.0, 'total_weight_main_karat': 0.0},
        {'name': 'كسر مؤقتة', 'balance_cash': 0.0, 'total_weight_main_karat': -446.672},
        # 24k below zero, the safe's gold above it: the drift check's
        {'name': 'مكتب', 'balance_cash': 0.0, 'total_weight_main_karat': 396.4,
         'weight_balance': {'21k': 396.6, '24k': -0.18}},
    ]
    said = {s['safe']: s for s in alerts(rows)['negative_safes']}
    assert said['صندوق']['cash'] == -250.0
    assert said['كسر مؤقتة']['grams'] == -446.672
    assert 'مكتب' not in said
