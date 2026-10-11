"""VAT returns (ADR-043, rule 5): preview, file, list -- services/vat_return.py decides."""
from datetime import date, datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import db

vat_returns_bp = Blueprint('vat_returns', __name__)


def _period(data):
    return date.fromisoformat(str(data.get('start') or '')), date.fromisoformat(str(data.get('end') or ''))


def _file(dry_run):
    from services.vat_return import VatReturnRefused, file_vat_return
    data = request.get_json(silent=True) or {}
    try:
        start, end = _period(data)
    except ValueError:
        return jsonify({'error': 'INVALID_DATE', 'message': 'بداية الفترة ونهايتها تاريخان'}), 400
    by = getattr(getattr(g, 'current_user', None), 'username', None) or 'system'
    try:
        out = file_vat_return(start=start, end=end, by=by, now=datetime.now(), dry_run=dry_run)
        if not dry_run:                     # a preview writes nothing: nothing to undo
            db.session.commit()
    except VatReturnRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 409 if refused.code == 'PERIOD_OVERLAPS' else 400
    return jsonify(out), 200 if dry_run else 201


@vat_returns_bp.route('/vat-returns/preview', methods=['POST'])
@require_permission('journal.view')
def preview_vat_return():
    return _file(dry_run=True)


@vat_returns_bp.route('/vat-returns', methods=['POST'])
@require_permission('journal.post')
def file_vat_return_route():
    return _file(dry_run=False)


@vat_returns_bp.route('/vat-returns', methods=['GET'])
@require_permission('journal.view')
def list_vat_returns_route():
    from services.vat_return import list_vat_returns
    return jsonify(list_vat_returns())
