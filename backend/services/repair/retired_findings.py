"""The open findings of a check no job runs any more, closed (the owner, 30 Oct 2026).

A finding is closed by the job that wrote it, when its fact clears
(reconcile_findings). A retired kind has no job: its open rows stay open
for ever. INVENTORY_LEDGER_DRIFT's four, from 14 Oct 2026 -- the old
inventory ledger and its check retired by ADR-045 C3 -- read on «نتائج الفحص
الليلي» as a code, and the owner agreed they close: «نعم».

Each open row of a kind in finding_kinds.RETIRED_KINDS is resolved at *now*,
and an audit row names each one, with its metric and detail as they were --
the history stays, resolved. Nothing else is touched. dry_run (the default)
writes nothing; a second run finds nothing to close.
"""
import json

from models import AuditLog, ReconciliationFinding, db
from services.finding_kinds import RETIRED_KINDS

ACTION = 'repair_close_retired_findings'


def close_retired_findings(*, by: str, now, dry_run: bool = True) -> dict:
    rows = (ReconciliationFinding.query
            .filter(ReconciliationFinding.kind.in_(sorted(RETIRED_KINDS)),
                    ReconciliationFinding.resolved_at.is_(None))
            .order_by(ReconciliationFinding.id).all())
    closed = [{'id': r.id, 'kind': r.kind, 'subject_key': r.subject_key, 'metric': r.metric,
               'opened': r.created_at.isoformat() if r.created_at else None} for r in rows]
    plan = {'closed': closed, 'count': len(closed)}
    if dry_run or not rows:
        return plan
    for r in rows:
        r.resolved_at = now
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='reconciliation_finding',
                            entity_id=rows[0].id, success=True,
                            details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
