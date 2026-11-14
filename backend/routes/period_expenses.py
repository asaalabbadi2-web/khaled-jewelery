"""Period expenses (ADR-090): list, read, create -- services/period_expense.py decides."""
from datetime import date, datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import db

period_expenses_bp = Blueprint('period_expenses', __name__)


def _as_of():
    raw = request.args.get('as_of')
    return date.fromisoformat(raw) if raw else date.today()


@period_expenses_bp.route('/period-expenses', methods=['GET'])
@require_permission('journal.view')
def list_period_expenses():
    from models import PeriodExpense
    from services.period_expense import to_dict
    try:
        day = _as_of()
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'التاريخ يُكتب YYYY-MM-DD'}), 400
    rows = PeriodExpense.query.order_by(PeriodExpense.period_start.desc(), PeriodExpense.id.desc()).all()
    return jsonify([to_dict(pe, day) for pe in rows]), 200


@period_expenses_bp.route('/period-expenses/<int:expense_id>', methods=['GET'])
@require_permission('journal.view')
def get_period_expense(expense_id):
    from models import PeriodExpense
    from services.period_expense import to_dict
    pe = db.session.get(PeriodExpense, expense_id)
    if pe is None:
        return jsonify({'error': 'period_expense_not_found'}), 404
    try:
        day = _as_of()
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'التاريخ يُكتب YYYY-MM-DD'}), 400
    return jsonify(to_dict(pe, day)), 200


@period_expenses_bp.route('/period-expenses', methods=['POST'])
@require_permission('journal.create')
def create_period_expense():
    from services.period_expense import PeriodExpenseRefused, create, to_dict
    data = request.get_json(silent=True) or {}
    try:
        start = date.fromisoformat(str(data.get('period_start') or ''))
        end = date.fromisoformat(str(data.get('period_end') or ''))
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'بداية الفترة ونهايتها تاريخان YYYY-MM-DD'}), 400
    by = getattr(getattr(g, 'current_user', None), 'username', None) or 'system'
    try:
        pe = create(description=data.get('description'), expense_account_id=data.get('expense_account_id'),
                    amount=data.get('amount') or 0, period_start=start, period_end=end,
                    by=by, now=datetime.now())
        db.session.commit()
    except PeriodExpenseRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    return jsonify(to_dict(pe, date.today())), 201
