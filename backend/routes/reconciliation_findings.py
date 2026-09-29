"""Read the findings the books invariants and reconciliation jobs record.

Thin by design: parsing here, the query in services/books_invariants.py. Read
only -- nothing on this surface resolves or changes a finding. Resolving
reviewed findings is a later step, together with a screen.
"""
from __future__ import annotations

from datetime import datetime

from flask import Blueprint, jsonify, request

from auth_decorators import require_auth, require_permission
from services.books_invariants import list_findings

reconciliation_findings_bp = Blueprint('reconciliation_findings', __name__)

_STATUSES = ('open', 'resolved', 'all')


@reconciliation_findings_bp.route('/reconciliation/findings', methods=['GET'])
@require_auth
@require_permission('reports.financial')
def get_reconciliation_findings():
    status = (request.args.get('status') or 'open').strip().lower()
    if status not in _STATUSES:
        return jsonify({'error': 'invalid_status', 'allowed': list(_STATUSES)}), 400

    since = None
    raw_since = (request.args.get('since') or '').strip()
    if raw_since:
        try:
            since = datetime.fromisoformat(raw_since.replace('Z', ''))
        except ValueError:
            return jsonify({'error': 'invalid_since', 'expected': 'ISO-8601 datetime'}), 400

    try:
        limit = int(request.args.get('limit', 500))
    except (TypeError, ValueError):
        return jsonify({'error': 'invalid_limit'}), 400

    findings = list_findings(
        status=status,
        kind=(request.args.get('kind') or None),
        source=(request.args.get('source') or None),
        since=since,
        limit=limit,
    )
    by_kind: dict = {}
    for f in findings:
        by_kind[f['kind']] = by_kind.get(f['kind'], 0) + 1
    return jsonify({'status': status, 'count': len(findings),
                    'by_kind': by_kind, 'findings': findings}), 200
