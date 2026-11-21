"""«الجرد بالمسح» (ADR-085 ت2): a location's pieces counted by their tags.

GET  /api/piece-scans/locations      -- the stock safes a scan counts (inventory.count)
GET  /api/piece-scans/open           -- the scans still open, to go back to (inventory.count)
POST /api/piece-scans                -- a scan opened: safe_box_id, kind (opening |
     closing | check), its scope section_id or category_id or neither; its
     snapshot taken now (inventory.count)
POST /api/piece-scans/<id>/reads     -- a batch of what the reader sent: batch_key,
     events [{kind: read | button, value, press, ms}]; answers the scan as it
     stands, each read judged (inventory.count)
POST /api/piece-scans/<id>/finish    -- its verdicts frozen; early: true with a
     reason when not complete (inventory.count)
POST /api/piece-scans/<id>/abandon   -- left, nothing judged (inventory.count)
GET  /api/piece-scans/<id>           -- a scan and its lists (inventory.view)
GET  /api/piece-scans                -- the scans, the newest first (inventory.view)

No entry, no stock moved. The laws are services/piece_scan.py's.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import PieceScan, db
from services.piece_scan import (ScanRefused, abandon_scan, finish_scan, scan_locations, scan_view, scans_list,
                                 start_scan, take_reads)

piece_scans_bp = Blueprint('piece_scans', __name__)


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


def _refused(refused: ScanRefused):
    db.session.rollback()
    status = 404 if refused.code == 'scan_not_found' else 400
    return jsonify({'error': refused.code, 'message': refused.message}), status


@piece_scans_bp.route('/piece-scans/locations', methods=['GET'])
@require_permission('inventory.count')
def piece_scan_locations():
    return jsonify({'locations': [{'id': s.id, 'name': s.name, 'stock_location': s.stock_location}
                                  for s in scan_locations()]}), 200


@piece_scans_bp.route('/piece-scans/open', methods=['GET'])
@require_permission('inventory.count')
def piece_scans_open():
    """The scans still open -- a reader's page reloaded goes back to its own."""
    return jsonify({'scans': scans_list(limit=20, status='open')}), 200


@piece_scans_bp.route('/piece-scans', methods=['POST'])
@require_permission('inventory.count')
def piece_scan_start():
    data = request.get_json(silent=True) or {}
    try:
        scan = start_scan(safe_box_id=data.get('safe_box_id'), kind=data.get('kind'), by=_by(), now=datetime.now(),
                          section_id=data.get('section_id'), category_id=data.get('category_id'))
    except ScanRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify({'scan': scan_view(scan)}), 201


@piece_scans_bp.route('/piece-scans/<int:scan_id>/reads', methods=['POST'])
@require_permission('inventory.count')
def piece_scan_reads(scan_id: int):
    data = request.get_json(silent=True) or {}
    try:
        scan = take_reads(scan_id, batch_key=data.get('batch_key'), events=data.get('events'), now=datetime.now())
    except ScanRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify({'scan': scan_view(scan)}), 200


@piece_scans_bp.route('/piece-scans/<int:scan_id>/finish', methods=['POST'])
@require_permission('inventory.count')
def piece_scan_finish(scan_id: int):
    data = request.get_json(silent=True) or {}
    try:
        scan = finish_scan(scan_id, by=_by(), now=datetime.now(), early=data.get('early') is True,
                           reason=data.get('reason'))
    except ScanRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify({'scan': scan_view(scan)}), 200


@piece_scans_bp.route('/piece-scans/<int:scan_id>/abandon', methods=['POST'])
@require_permission('inventory.count')
def piece_scan_abandon(scan_id: int):
    try:
        scan = abandon_scan(scan_id, by=_by(), now=datetime.now())
    except ScanRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify({'scan': scan_view(scan)}), 200


@piece_scans_bp.route('/piece-scans/<int:scan_id>', methods=['GET'])
@require_permission('inventory.view')
def piece_scan_get(scan_id: int):
    scan = db.session.get(PieceScan, scan_id)
    if scan is None:
        return jsonify({'error': 'scan_not_found', 'message': 'جلسة الجرد غير موجودة'}), 404
    return jsonify({'scan': scan_view(scan)}), 200


@piece_scans_bp.route('/piece-scans', methods=['GET'])
@require_permission('inventory.view')
def piece_scans_get():
    return jsonify({'scans': scans_list()}), 200
