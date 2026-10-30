"""The open findings of a retired check close, and nothing else (the owner, 30 Oct 2026).

INVENTORY_LEDGER_DRIFT's check was retired (ADR-045 C3) and nothing closes
its open rows: four, from 14 Oct 2026, on production. The owner: «نعم».

Run:
    python -m pytest tests/test_retired_findings_close.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import AuditLog, ReconciliationFinding, db
from services.repair.retired_findings import ACTION, close_retired_findings

NOW = datetime(2026, 10, 30, 12, 0)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _finding(kind):
    row = ReconciliationFinding(kind=kind, source='books_invariants', subject_key=f'x:{uuid.uuid4().hex[:8]}',
                                metric=-10405.51, created_at=datetime(2026, 10, 14))
    db.session.add(row)
    db.session.flush()
    return row


def test_a_retired_kind_closes_and_a_live_one_stays(app):
    retired, live = _finding('INVENTORY_LEDGER_DRIFT'), _finding('ORPHAN_POSTED_ENTRY')

    plan = close_retired_findings(by='t', now=NOW)                      # dry run
    assert retired.id in {c['id'] for c in plan['closed']}
    assert retired.resolved_at is None, 'a dry run writes nothing'

    close_retired_findings(by='المالك', now=NOW, dry_run=False)
    assert retired.resolved_at == NOW
    assert live.resolved_at is None, 'a live check closes its own'
    audit = AuditLog.query.filter_by(action=ACTION).order_by(AuditLog.id.desc()).first()
    assert audit.user_name == 'المالك' and str(retired.id) in audit.details

    assert close_retired_findings(by='t', now=NOW, dry_run=False)['count'] == 0, 'a second run closes nothing'
