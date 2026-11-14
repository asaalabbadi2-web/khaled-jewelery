"""The period lock (ADR-090, law 9): read it, and move it -- services/period_lock.py decides."""
from datetime import date, datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import db

period_lock_bp = Blueprint('period_lock', __name__)


@period_lock_bp.route('/period-lock', methods=['GET'])
@require_permission('journal.view')
def get_period_lock():
    from services.period_lock import current, history
    closed = current()
    return jsonify({'closed_through': closed.isoformat() if closed else None, 'history': history()}), 200


@period_lock_bp.route('/period-lock', methods=['POST'])
@require_permission('accounting.period_lock')
def move_period_lock():
    from services.period_lock import PeriodLockRefused, move
    data = request.get_json(silent=True) or {}
    raw = data.get('closed_through')
    try:
        closed_through = date.fromisoformat(str(raw)) if raw else None
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'تاريخ القفل يُكتب YYYY-MM-DD'}), 400
    by = getattr(getattr(g, 'current_user', None), 'username', None) or 'system'
    try:
        row = move(closed_through, reason=data.get('reason'), by=by, now=datetime.now())
        db.session.commit()
    except PeriodLockRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    return jsonify(row.to_dict()), 201
