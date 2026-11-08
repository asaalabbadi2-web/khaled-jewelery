"""«محطة ترميز القطع» (ADR-087 R3.4): the station's routes.

GET  /api/pieces/pending          -- posted receipt lines of categories tracked
     by the piece with weight left to code: their pieces counted, the rest.
GET  /api/pieces/lines/<line_id>  -- a line and its pieces, each with its wage
     (read from its line, §6) or «بانتظار الفاتورة».
GET  /api/pieces/codings/<id>     -- a batch of existing stock and its pieces.
POST /api/pieces                  -- a piece under a line (line_id) or a batch
     (coding_id): weight, stones_weight, request_key -- the save attempt's
     key: pressed twice, one.
GET  /api/stock-codings/free      -- what a location holds of a category not
     yet pieced nor promised to an open batch (safe_box_id, category_id).
POST /api/stock-codings           -- «ترميز من المخزون الموجود»: a batch --
     safe_box_id, category_id, weight, wage_per_gram (by hand), note.
The laws are services/pieces.py's; these only carry them.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request
from sqlalchemy.exc import IntegrityError

from auth_decorators import require_permission
from models import Category, InvoiceItem, Item, SafeBox, StockCoding, db
from services.pieces import (PieceRefused, coding_view, free_grams, line_pieces, line_view, open_coding,
                             pending_lines, piece_source, piece_view, register_piece, reserved_grams)

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


@pieces_bp.route('/pieces/codings/<int:coding_id>', methods=['GET'])
@require_permission('items.view')
def station_coding(coding_id: int):
    batch = db.session.get(StockCoding, coding_id)
    if batch is None:
        return jsonify({'error': 'not_found', 'message': 'دفعة الترميز غير موجودة'}), 404
    return jsonify({'line': coding_view(batch), 'pieces': [piece_view(p) for p in line_pieces(batch)]}), 200


def _view(source):
    return coding_view(source) if isinstance(source, StockCoding) else line_view(source)


def _saved(key):
    piece = Item.query.filter_by(request_key=key).first() if key else None
    if piece is None:
        return None
    return jsonify({'piece': piece_view(piece), 'line': _view(piece_source(piece)), 'already_saved': True}), 200


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
        line = (db.session.get(StockCoding, int(data['coding_id'])) if data.get('coding_id')
                else db.session.get(InvoiceItem, int(data.get('line_id'))))
    except (TypeError, ValueError):
        line = None
    if line is None:
        return jsonify({'error': 'not_found', 'message': 'سطر الاستلام أو دفعة الترميز غير موجودة'}), 404
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
    return jsonify({'piece': piece_view(piece), 'line': _view(line)}), 201


@pieces_bp.route('/stock-codings/free', methods=['GET'])
@require_permission('items.view')
def stock_coding_free():
    try:
        safe = db.session.get(SafeBox, int(request.args.get('safe_box_id')))
        category = db.session.get(Category, int(request.args.get('category_id')))
    except (TypeError, ValueError):
        safe = category = None
    if safe is None or category is None:
        return jsonify({'error': 'not_found', 'message': 'الخزينة أو التصنيف غير موجود'}), 404
    karat = int(round(float(category.karat or 0)))
    free = free_grams(safe, karat, category.id)
    reserved = reserved_grams(safe.id, karat, category.id)
    return jsonify({'free': free, 'reserved': reserved, 'room': round(max(free - reserved, 0.0), 3),
                    'karat': karat}), 200


@pieces_bp.route('/stock-codings', methods=['POST'])
@require_permission('items.create')
def stock_coding_open():
    data = request.get_json(silent=True) or {}
    try:
        batch = open_coding(safe_box_id=data.get('safe_box_id'), category_id=data.get('category_id'),
                            weight=data.get('weight'), wage_per_gram=data.get('wage_per_gram'),
                            note=data.get('note'), by=_by(), now=datetime.now())
    except PieceRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    db.session.commit()
    return jsonify({'line': coding_view(batch), 'pieces': []}), 201
