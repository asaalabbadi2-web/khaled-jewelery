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
    import json
    from models import PeriodExpenseRevision
    revisions = [{'reason': r.reason, 'before': json.loads(r.before), 'after': json.loads(r.after),
                  'changed_by': r.changed_by, 'changed_at': r.changed_at.isoformat()}
                 for r in PeriodExpenseRevision.query.filter_by(period_expense_id=pe.id)
                 .order_by(PeriodExpenseRevision.id.desc())]
    return jsonify({**to_dict(pe, day), 'revisions': revisions}), 200


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


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


@period_expenses_bp.route('/period-expenses/accrue', methods=['POST'])
@require_permission('journal.post')
def accrue_period_expenses():
    """The month-end action (law 6): {through, apply}. Without apply, a preview
    -- the entries it would write, written in a savepoint and rolled back."""
    from services.period_expense import PeriodExpenseRefused, accrue
    data = request.get_json(silent=True) or {}
    try:
        through = date.fromisoformat(str(data.get('through') or ''))
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'آخر يوم يُستحق حتى يُكتب YYYY-MM-DD'}), 400
    if through >= date.today():
        return jsonify({'error': 'not_past', 'message': 'يُستحق ما انتهى من الأشهر فقط.'}), 400
    apply = bool(data.get('apply'))
    try:
        plan = accrue(through, by=_by(), now=datetime.now(), dry_run=not apply)
        if apply:
            db.session.commit()
        # a preview rolled its own savepoint back: nothing to undo here, and
        # nothing else of the session's to undo with it
    except PeriodExpenseRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    return jsonify({'applied': apply, **plan}), 201 if apply else 200


def _dated(data, key):
    raw = data.get(key)
    return date.fromisoformat(str(raw)) if raw else None


@period_expenses_bp.route('/period-expenses/<int:expense_id>', methods=['PUT'])
@require_permission('journal.edit')
def edit_period_expense(expense_id):
    from models import PeriodExpense
    from services.period_expense import PeriodExpenseRefused, edit, to_dict
    pe = db.session.get(PeriodExpense, expense_id)
    if pe is None:
        return jsonify({'error': 'period_expense_not_found'}), 404
    data = request.get_json(silent=True) or {}
    try:
        start, end = _dated(data, 'period_start'), _dated(data, 'period_end')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'التاريخ يُكتب YYYY-MM-DD'}), 400
    try:
        edit(pe, reason=data.get('reason'), by=_by(), now=datetime.now(), amount=data.get('amount'),
             period_start=start, period_end=end)
        db.session.commit()
    except PeriodExpenseRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    return jsonify(to_dict(pe, date.today())), 200


@period_expenses_bp.route('/period-expenses/<int:expense_id>/cancel', methods=['POST'])
@require_permission('journal.edit')
def cancel_period_expense(expense_id):
    from models import PeriodExpense
    from services.period_expense import PeriodExpenseRefused, cancel, to_dict
    pe = db.session.get(PeriodExpense, expense_id)
    if pe is None:
        return jsonify({'error': 'period_expense_not_found'}), 404
    data = request.get_json(silent=True) or {}
    try:
        cancel(pe, reason=data.get('reason'), by=_by(), now=datetime.now())
        db.session.commit()
    except PeriodExpenseRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    return jsonify(to_dict(pe, date.today())), 200
