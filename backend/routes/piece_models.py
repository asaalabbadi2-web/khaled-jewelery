"""«الموديلات» (ADR-093 M1): the piece models' routes.

GET    /api/piece-models          -- ?category_id, q, include_inactive: each
       with its sizes, its thumbnail and how many pieces are of it.
GET    /api/piece-models/<id>     -- one model; its photo and thumbnail are
       attachments (GET /api/attachments/<id>, ADR-094).
GET    /api/piece-models/board    -- ?category_id: its models and their stock
       size by size, and «بلا موديل» -- adding up to the category's stock.
GET    /api/piece-models/stock-grid -- ?model_id, or ?category_id&model_id=none:
       the pieces in stock size by size, lightest first, with their place.
POST   /api/piece-models          -- {category_id, name, supplier_code,
       expected_wage_per_gram, has_stones, size_ids, photo_id, thumbnail_id}.
PATCH  /api/piece-models/<id>     -- what is given changes; is_active stops it.
DELETE /api/piece-models/<id>     -- one no piece is of.
The laws are services/piece_models.py's; these only carry them.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import PieceModel, db
from services.piece_models import ModelRefused, create_model, delete_model, list_models, model_view, update_model

piece_models_bp = Blueprint('piece_models', __name__)

_FIELDS = ('name', 'category_id', 'supplier_code', 'expected_wage_per_gram', 'has_stones', 'size_ids', 'photo_id',
           'thumbnail_id', 'is_active')


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


def _refused(refused: ModelRefused):
    db.session.rollback()
    return jsonify({'error': refused.code, 'message': refused.message}), 400


def _truthy(raw) -> bool:
    return (raw or '').strip().lower() in ('1', 'true', 'yes')


@piece_models_bp.route('/piece-models', methods=['GET'])
@require_permission('items.view')
def piece_models_index():
    return jsonify(list_models(category_id=request.args.get('category_id'), q=request.args.get('q'),
                               include_inactive=_truthy(request.args.get('include_inactive'))))


@piece_models_bp.route('/piece-models/board', methods=['GET'])
@require_permission('items.view')
def piece_models_board():
    """?category_id: its models and their stock size by size, and «بلا موديل»."""
    from services.piece_models import models_board
    try:
        return jsonify(models_board(request.args.get('category_id')))
    except ModelRefused as refused:
        return jsonify({'error': refused.code, 'message': refused.message}), 400


@piece_models_bp.route('/piece-models/stock-grid', methods=['GET'])
@require_permission('items.view')
def piece_models_stock_grid():
    """?model_id, or ?category_id&model_id=none: the pieces in stock size by size, lightest first."""
    from services.piece_models import stock_grid
    try:
        return jsonify(stock_grid(category_id=request.args.get('category_id'), model_id=request.args.get('model_id')))
    except ModelRefused as refused:
        return jsonify({'error': refused.code, 'message': refused.message}), 400


@piece_models_bp.route('/piece-models/<int:model_id>', methods=['GET'])
@require_permission('items.view')
def piece_models_show(model_id):
    return jsonify(model_view(PieceModel.query.get_or_404(model_id)))


@piece_models_bp.route('/piece-models', methods=['POST'])
@require_permission('items.edit')
def piece_models_create():
    data = request.get_json(silent=True) or {}
    try:
        model = create_model(category_id=data.get('category_id'), name=data.get('name'),
                             supplier_code=data.get('supplier_code'),
                             expected_wage_per_gram=data.get('expected_wage_per_gram'),
                             has_stones=bool(data.get('has_stones')), size_ids=data.get('size_ids') or (),
                             photo_id=data.get('photo_id'), thumbnail_id=data.get('thumbnail_id'), by=_by(),
                             now=datetime.now())
    except ModelRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(model_view(model)), 201


@piece_models_bp.route('/piece-models/<int:model_id>', methods=['PATCH'])
@require_permission('items.edit')
def piece_models_update(model_id):
    model = PieceModel.query.get_or_404(model_id)
    data = request.get_json(silent=True) or {}
    try:
        update_model(model, now=datetime.now(), by=_by(), **{k: data[k] for k in _FIELDS if k in data})
    except ModelRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(model_view(model))


@piece_models_bp.route('/piece-models/<int:model_id>', methods=['DELETE'])
@require_permission('items.edit')
def piece_models_delete(model_id):
    model = PieceModel.query.get_or_404(model_id)
    try:
        delete_model(model)
    except ModelRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify({'deleted': model_id})
