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
        row = move(closed_through, reason=data.get('reason'), by=by, now=datetime.now(),
                   accept_pending=bool(data.get('accept_pending')))
        db.session.commit()
    except PeriodLockRefused as refused:
        db.session.rollback()
        body = {'error': refused.code, 'message': refused.message}
        if refused.detail is not None:
            body['pending'] = refused.detail
        return jsonify(body), 409 if refused.code == 'pending_in_period' else 400
    return jsonify(row.to_dict()), 201


@period_lock_bp.route('/period-lock/pending', methods=['GET'])
@require_permission('journal.view')
def get_pending_before_close():
    """What waits in the months a lock through ?through= would close, after the lock now."""
    from services.period_lock import current, pending
    try:
        through = date.fromisoformat(request.args.get('through') or '')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'تاريخ القفل يُكتب YYYY-MM-DD'}), 400
    return jsonify({'after': current().isoformat() if current() else None, 'through': through.isoformat(),
                    **pending(current(), through)}), 200
