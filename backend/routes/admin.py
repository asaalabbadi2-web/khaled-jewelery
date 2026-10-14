"""Admin & temp-pdf domain routes — admin_bp registered under /api in app.py."""
from __future__ import annotations

import os
import secrets
import time as _time
from datetime import datetime, timedelta

from flask import Blueprint, g, jsonify, request, send_file

from models import (
    db,
    JournalEntry,
    SafeBoxTransaction,
    VoucherAccountLine,
)

from auth_decorators import require_permission

admin_bp = Blueprint('admin', __name__)

_TEMP_PDF_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'temp_pdfs')
_TEMP_PDF_MAX_BYTES = 10 * 1024 * 1024   # 10 MB per upload
_TEMP_PDF_TTL_SECONDS = 86400             # 24 hours


def _temp_pdf_lazy_cleanup():
    """Remove temp PDF files older than _TEMP_PDF_TTL_SECONDS (best-effort)."""
    import time as _time
    try:
        cutoff = _time.time() - _TEMP_PDF_TTL_SECONDS
        for fname in os.listdir(_TEMP_PDF_DIR):
            fpath = os.path.join(_TEMP_PDF_DIR, fname)
            try:
                if os.path.isfile(fpath) and os.path.getmtime(fpath) < cutoff:
                    os.remove(fpath)
            except OSError:
                pass
    except OSError:
        pass


@admin_bp.route('/temp-pdf', methods=['POST'])
def upload_temp_pdf():
    """
    Accept raw PDF bytes (Content-Type: application/pdf).
    Returns: {"token": "<url-safe token>"} with status 201.
    The caller builds the download URL as <api_base>/temp-pdf/<token>.
    """
    import secrets
    import re

    data = request.get_data()
    if not data:
        return jsonify({'error': 'empty body'}), 400
    if len(data) > _TEMP_PDF_MAX_BYTES:
        return jsonify({'error': 'file too large'}), 413

    # Validate that the payload looks like a PDF.
    if not data.startswith(b'%PDF'):
        return jsonify({'error': 'not a PDF'}), 400

    os.makedirs(_TEMP_PDF_DIR, exist_ok=True)
    _temp_pdf_lazy_cleanup()

    token = secrets.token_urlsafe(24)  # 32 url-safe chars, no path traversal risk
    # Paranoid check: token must be safe for filesystem and URL use.
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', token):
        token = secrets.token_hex(24)

    filepath = os.path.join(_TEMP_PDF_DIR, f'{token}.pdf')
    with open(filepath, 'wb') as fh:
        fh.write(data)

    return jsonify({'token': token}), 201


@admin_bp.route('/temp-pdf/<string:token>', methods=['GET'])
def serve_temp_pdf(token):
    """
    Serve a previously uploaded temporary PDF.
    Validates the token strictly to prevent path traversal.
    """
    import re
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', token):
        return jsonify({'error': 'invalid token'}), 400

    filepath = os.path.join(_TEMP_PDF_DIR, f'{token}.pdf')
    # os.path.abspath check guards against any remaining traversal risk.
    if not os.path.abspath(filepath).startswith(os.path.abspath(_TEMP_PDF_DIR)):
        return jsonify({'error': 'invalid token'}), 400
    if not os.path.isfile(filepath):
        return jsonify({'error': 'not found or expired'}), 404

    return send_file(filepath, mimetype='application/pdf', as_attachment=False)


# Employees domain → routes/employees.py (achievements + goals)
# (GET /achievements/unseen, POST /achievements/<id>/mark-seen,
#  POST /achievements, POST /achievements/check-progress,
#  PATCH /employees/<id>/goals)



# ═══════════════════════════════════════════════════════════════════════════
#  HistoricalClearingAdjustment — Admin API
# ═══════════════════════════════════════════════════════════════════════════

@admin_bp.route('/admin/historical-clearing-adjustment', methods=['GET'])
@require_permission('system.settings')
def list_historical_clearing_adjustments():
    """List all HistoricalClearingAdjustment records (newest first)."""
    from models import HistoricalClearingAdjustment as HCA
    rows = HCA.query.order_by(HCA.id.desc()).all()
    return jsonify({'adjustments': [r.to_dict() for r in rows]}), 200


@admin_bp.route('/admin/historical-clearing-adjustment', methods=['POST'])
@require_permission('system.settings')
def create_historical_clearing_adjustment():
    """Create a pending HistoricalClearingAdjustment.

    Body:
      {
        "safe_box_id": 32,
        "amount": 6050.00,
        "adjustment_type": "historical_allocation_gap",
        "reason": "...",
        "reference_voucher_number": "AV-2026-00133"   // optional
      }
    """
    from historical_clearing_adjustment_service import HistoricalClearingAdjustmentService

    data = request.get_json(force=True) or {}
    required = ('safe_box_id', 'amount', 'adjustment_type', 'reason')
    missing = [f for f in required if not data.get(f)]
    if missing:
        return jsonify({'error': f'missing fields: {missing}'}), 400

    actor = getattr(g, 'current_user', None)
    created_by = actor.username if actor else 'admin'

    try:
        svc = HistoricalClearingAdjustmentService()
        adj = svc.create(
            safe_box_id=int(data['safe_box_id']),
            amount=float(data['amount']),
            adjustment_type=data['adjustment_type'],
            reason=data['reason'],
            created_by=created_by,
            reference_voucher_number=data.get('reference_voucher_number'),
        )
        db.session.commit()
        return jsonify({'adjustment': adj.to_dict()}), 201
    except ValueError as exc:
        db.session.rollback()
        return jsonify({'error': str(exc)}), 400


@admin_bp.route('/admin/historical-clearing-adjustment/<int:adj_id>/apply', methods=['POST'])
@require_permission('system.settings')
def apply_historical_clearing_adjustment(adj_id):
    """Apply a pending adjustment: creates SafeBoxTransaction + JournalEntry.

    Body:
      {
        "clearing_account_id": 777,
        "contra_account_id": 900
      }
    """
    from historical_clearing_adjustment_service import HistoricalClearingAdjustmentService

    data = request.get_json(force=True) or {}
    clearing_account_id = data.get('clearing_account_id')
    contra_account_id = data.get('contra_account_id')
    if not clearing_account_id or not contra_account_id:
        return jsonify({'error': 'clearing_account_id and contra_account_id required'}), 400

    actor = getattr(g, 'current_user', None)
    applied_by = actor.username if actor else 'admin'

    try:
        from historical_clearing_adjustment_service import AlreadyAppliedError
        svc = HistoricalClearingAdjustmentService()
        adj = svc.apply(
            adjustment_id=adj_id,
            applied_by=applied_by,
            clearing_account_id=int(clearing_account_id),
            contra_account_id=int(contra_account_id),
        )
        db.session.commit()
        return jsonify({'adjustment': adj.to_dict()}), 200
    except AlreadyAppliedError as exc:
        db.session.rollback()
        return jsonify({'error': str(exc), 'code': 'already_applied'}), 409
    except ValueError as exc:
        db.session.rollback()
        return jsonify({'error': str(exc)}), 400


@admin_bp.route('/admin/historical-clearing-adjustment/<int:adj_id>/cancel', methods=['POST'])
@require_permission('system.settings')
def cancel_historical_clearing_adjustment(adj_id):
    """Cancel a pending adjustment.

    Body: {"reason": "..."}
    """
    from historical_clearing_adjustment_service import HistoricalClearingAdjustmentService

    data = request.get_json(force=True) or {}
    reason = data.get('reason', '')

    actor = getattr(g, 'current_user', None)
    cancelled_by = actor.username if actor else 'admin'

    try:
        svc = HistoricalClearingAdjustmentService()
        adj = svc.cancel(
            adjustment_id=adj_id,
            cancelled_by=cancelled_by,
            reason=reason,
        )
        db.session.commit()
        return jsonify({'adjustment': adj.to_dict()}), 200
    except ValueError as exc:
        db.session.rollback()
        return jsonify({'error': str(exc)}), 400

