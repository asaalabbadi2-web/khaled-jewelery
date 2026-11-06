"""A new year's opening figures (ADR-044, TR-2): the manager enters, the owner approves.

    GET  /api/opening/<year>                 the rows, their figures, the difference
    PUT  /api/opening/<year>/<account_id>    one account's figure       (opening.enter)
    POST /api/opening/<year>/approve         the year's figures lock    (opening.approve)

services/opening_figures. The owner, 6 Nov 2026: «المدير يُدخل، والمالك يعتمد».
"""
from __future__ import annotations

from datetime import datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import db

opening_bp = Blueprint('opening', __name__, url_prefix='/api/opening')


def _by() -> str:
    u = getattr(g, 'current_user', None)
    return getattr(u, 'username', None) or 'unknown'


@opening_bp.route('/<int:year>', methods=['GET'])
@require_permission('opening.enter')
def get_opening(year: int):
    from services.opening_figures import opening
    return jsonify(opening(year)), 200


@opening_bp.route('/<int:year>/<int:account_id>', methods=['PUT'])
@require_permission('opening.enter')
def put_figure(year: int, account_id: int):
    from services.opening_figures import OpeningRefused, enter, opening
    data = request.get_json(silent=True) or {}
    try:
        enter(year, account_id, cash=data.get('cash'), karats=data.get('karats') or {},
              source=data.get('source'), treatment=data.get('treatment'), note=data.get('note'),
              by=_by(), now=datetime.now())
        db.session.commit()
    except OpeningRefused as refused:
        db.session.rollback()
        return jsonify({'error': 'opening_refused', 'message': str(refused)}), 400
    return jsonify(opening(year)), 200


@opening_bp.route('/<int:year>/approve', methods=['POST'])
@require_permission('opening.approve')
def approve_opening(year: int):
    from services.opening_figures import OpeningRefused, approve, opening
    try:
        approve(year, by=_by(), now=datetime.now())
        db.session.commit()
    except OpeningRefused as refused:
        db.session.rollback()
        return jsonify({'error': 'opening_refused', 'message': str(refused)}), 400
    return jsonify(opening(year)), 200
