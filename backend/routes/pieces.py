"""«محطة ترميز القطع» (ADR-087 R3.4): the station's routes.

GET  /api/pieces/pending          -- posted receipt lines of categories tracked
     by the piece with weight left to code: their pieces counted, the rest.
GET  /api/pieces/lines/<line_id>  -- a line and its pieces, each with its wage
     (read from its line, §6) or «بانتظار الفاتورة».
POST /api/pieces                  -- a piece under a line: line_id, weight,
     stones_weight, request_key -- the save attempt's key: pressed twice, one.
The laws are services/pieces.py's; these only carry them.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request
from sqlalchemy.exc import IntegrityError

from auth_decorators import require_permission
from models import InvoiceItem, Item, db
from services.pieces import PieceRefused, line_view, pending_lines, piece_view, register_piece, line_pieces

pieces_bp = Blueprint('pieces', __name__)


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


@pieces_bp.route('/pieces/pending', methods=['GET'])
@require_permission('items.view')
def station_pending():
    return jsonify({'lines': pending_lines()}), 200


@pieces_bp.route('/pieces/lines/<int:line_id>', methods=['GET'])
@require_permission('items.view')
def station_line(line_id: int):
    line = db.session.get(InvoiceItem, line_id)
    if line is None:
        return jsonify({'error': 'not_found', 'message': 'سطر الاستلام غير موجود'}), 404
    return jsonify({'line': line_view(line), 'pieces': [piece_view(p) for p in line_pieces(line)]}), 200


def _saved(key):
    piece = Item.query.filter_by(request_key=key).first() if key else None
    if piece is None:
        return None
    line = db.session.get(InvoiceItem, piece.receipt_item_id)
    return jsonify({'piece': piece_view(piece), 'line': line_view(line), 'already_saved': True}), 200


@pieces_bp.route('/pieces', methods=['POST'])
@require_permission('items.create')
def station_register():
    data = request.get_json(silent=True) or {}
    key = (str(data.get('request_key') or '').strip() or None)
    if key and len(key) > 64:
        return jsonify({'error': 'request_key_invalid', 'message': 'مفتاح المحاولة أطول من 64'}), 400
    saved = _saved(key)
    if saved is not None:
        return saved
    try:
        line = db.session.get(InvoiceItem, int(data.get('line_id')))
    except (TypeError, ValueError):
        line = None
    if line is None:
        return jsonify({'error': 'not_found', 'message': 'سطر الاستلام غير موجود'}), 404
    try:
        with db.session.begin_nested():
            piece = register_piece(line, weight=data.get('weight'), stones_weight=data.get('stones_weight'),
                                   by=_by(), now=datetime.now(), request_key=key)
    except PieceRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    except IntegrityError:
        # two stations, one key, the same moment: the second meets the first's row
        db.session.rollback()
        saved = _saved(key)
        if saved is None:
            raise
        return saved
    db.session.commit()
    return jsonify({'piece': piece_view(piece), 'line': line_view(line)}), 201
