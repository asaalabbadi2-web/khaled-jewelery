"""«أنظمة المقاسات» (ADR-093 M0): the size systems' routes.

GET    /api/size-systems                  -- every system: its sizes in their
       order (each with the pieces it holds) and the categories that follow it.
POST   /api/size-systems                  -- {name, measurement_label, sizes: [label]}.
PATCH  /api/size-systems/<id>             -- {name, measurement_label}.
DELETE /api/size-systems/<id>             -- one no category follows.
POST   /api/size-systems/<id>/sizes       -- {label, measurement, before_id}.
PUT    /api/size-systems/<id>/order       -- {ids: [...]}: every size once.
PATCH  /api/size-system-sizes/<id>        -- {label, measurement}.
DELETE /api/size-system-sizes/<id>        -- one no piece holds.
A category's system is set by PUT /api/categories/<id> {size_system_id}.
The laws are services/size_systems.py's; these only carry them.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import SizeSystem, SizeSystemSize, db
from services.size_systems import (SizeRefused, add_size, create_system, delete_size, delete_system,
                                   list_systems, reorder, system_view, update_size, update_system)

size_systems_bp = Blueprint('size_systems', __name__)


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


def _refused(refused: SizeRefused):
    db.session.rollback()
    return jsonify({'error': refused.code, 'message': refused.message}), 400


def _system(system_id) -> SizeSystem:
    return SizeSystem.query.get_or_404(system_id)


@size_systems_bp.route('/size-systems', methods=['GET'])
@require_permission('items.view')
def size_systems_index():
    return jsonify(list_systems())


@size_systems_bp.route('/size-systems', methods=['POST'])
@require_permission('items.edit')
def size_systems_create():
    data = request.get_json(silent=True) or {}
    try:
        system = create_system(name=data.get('name'), measurement_label=data.get('measurement_label'),
                               sizes=data.get('sizes') or (), by=_by(), now=datetime.now())
    except SizeRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(system_view(system)), 201


@size_systems_bp.route('/size-systems/<int:system_id>', methods=['PATCH'])
@require_permission('items.edit')
def size_systems_update(system_id):
    system = _system(system_id)
    data = request.get_json(silent=True) or {}
    try:
        update_system(system, name=data.get('name'),
                      **({'measurement_label': data['measurement_label']} if 'measurement_label' in data else {}))
    except SizeRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(system_view(system))


@size_systems_bp.route('/size-systems/<int:system_id>', methods=['DELETE'])
@require_permission('items.edit')
def size_systems_delete(system_id):
    system = _system(system_id)
    try:
        delete_system(system)
    except SizeRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify({'deleted': system_id})


@size_systems_bp.route('/size-systems/<int:system_id>/sizes', methods=['POST'])
@require_permission('items.edit')
def size_systems_add_size(system_id):
    system = _system(system_id)
    data = request.get_json(silent=True) or {}
    try:
        add_size(system, label=data.get('label'), measurement=data.get('measurement'),
                 before_id=data.get('before_id'), by=_by(), now=datetime.now())
    except SizeRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(system_view(system)), 201


@size_systems_bp.route('/size-systems/<int:system_id>/order', methods=['PUT'])
@require_permission('items.edit')
def size_systems_order(system_id):
    system = _system(system_id)
    data = request.get_json(silent=True) or {}
    try:
        reorder(system, data.get('ids'))
    except SizeRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(system_view(system))


@size_systems_bp.route('/size-system-sizes/<int:size_id>', methods=['PATCH'])
@require_permission('items.edit')
def size_systems_update_size(size_id):
    size = SizeSystemSize.query.get_or_404(size_id)
    data = request.get_json(silent=True) or {}
    try:
        update_size(size, label=data.get('label'),
                    **({'measurement': data['measurement']} if 'measurement' in data else {}))
    except SizeRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(system_view(db.session.get(SizeSystem, size.system_id)))


@size_systems_bp.route('/size-system-sizes/<int:size_id>', methods=['DELETE'])
@require_permission('items.edit')
def size_systems_delete_size(size_id):
    size = SizeSystemSize.query.get_or_404(size_id)
    system_id = size.system_id
    try:
        delete_size(size)
    except SizeRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify(system_view(db.session.get(SizeSystem, system_id)))
