"""Attachments' routes (ADR-094): a photo sent, a photo read, a record's photos.

POST /api/attachments              -- multipart: file, role (scrap_gold_photo,
     model_photo, model_thumbnail): kept by its fingerprint, pending under its
     sender until its record is saved; sent by its kind's right.
GET  /api/attachments/<id>         -- the file, through the server: the token
     and its kind's right to see checked; a pending one its sender's alone.
GET  /api/invoices/<id>/attachments -- the photos an invoice was saved with.
The laws are services/attachments.py's; these only carry them.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request, send_file

from auth_decorators import require_any_permission, require_permission
from models import Attachment, db
from services.attachments import (INVOICE, MAX_BYTES, ROLE_RIGHTS, AttachmentRefused, file_of, of_record, store,
                                  view)

attachments_bp = Blueprint('attachments', __name__)

SEND_RIGHTS = sorted({send for send, _ in ROLE_RIGHTS.values()})
SEE_RIGHTS = sorted({see for _, see in ROLE_RIGHTS.values()})


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


def _may(code: str) -> bool:
    """The signed-in user holds *code* (an admin every right) -- a kind's own right."""
    user = getattr(g, 'current_user', None)
    return bool(user is not None and (getattr(user, 'is_admin', False) or user.has_permission(code)))


@attachments_bp.route('/attachments', methods=['POST'])
@require_any_permission(*SEND_RIGHTS)
def attachments_upload():
    role = (request.form.get('role') or '').strip()
    if role not in ROLE_RIGHTS:
        return jsonify({'error': 'attachment_role_invalid', 'message': 'نوع المرفق غير معروف'}), 400
    if not _may(ROLE_RIGHTS[role][0]):
        return jsonify({'error': 'permission_denied', 'message': 'لا صلاحية لرفع هذا النوع من الصور'}), 403
    upload = request.files.get('file')
    if upload is None:
        return jsonify({'error': 'attachment_empty', 'message': 'لا ملف في الطلب'}), 400
    raw = upload.read(MAX_BYTES + 1)
    try:
        row = store(raw, role=role, by=_by(), now=datetime.now())
    except AttachmentRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    db.session.commit()
    return jsonify(view(row)), 201


@attachments_bp.route('/attachments/<int:attachment_id>', methods=['GET'])
@require_any_permission(*SEE_RIGHTS)
def attachments_read(attachment_id: int):
    row = db.session.get(Attachment, attachment_id)
    if row is None or (row.entity_id is None and row.uploaded_by != _by()):
        return jsonify({'error': 'not_found', 'message': 'الصورة غير موجودة'}), 404
    if not _may(ROLE_RIGHTS.get(row.role, (None, 'system.settings'))[1]):
        return jsonify({'error': 'permission_denied', 'message': 'لا صلاحية لعرض هذه الصورة'}), 403
    try:
        path, mime = file_of(row)
    except AttachmentRefused as refused:
        return jsonify({'error': refused.code, 'message': refused.message}), 404
    reply = send_file(path, mimetype=mime, etag=row.sha256, conditional=True, max_age=0)
    reply.headers['Cache-Control'] = 'private, max-age=86400'
    return reply


@attachments_bp.route('/invoices/<int:invoice_id>/attachments', methods=['GET'])
@require_permission('invoices.view')
def invoice_attachments(invoice_id: int):
    return jsonify(of_record(INVOICE, invoice_id))
