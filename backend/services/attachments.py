"""Attachments: a file on the server's disk, its record in the books (ADR-094).

The owner (17 Nov 2026), on «صور الذهب في شراء الكسر لا تُحفظ إطلاقًا» -- the
screen sent their count only: a photo is a file in a lasting folder
(MEDIA_ROOT, the volume media_data:/data/media in production), named by its
content's fingerprint (sha256) -- one photo kept once, no two names meet;
one table for every kind, its row the fingerprint, type, size, dimensions,
the record it belongs to, who sent it and when. So:
  - a photo is an image by its own first bytes -- JPEG, PNG or WebP --
    within its size and its side (sized down on the device first);
  - sent as it is taken, it waits (pending) under its sender; an invoice
    saved names its photos and they are linked in its own transaction --
    by their sender only, once, at most MAX_PER_RECORD a record;
  - it is read through the server, the user's token and right checked --
    never a bare link: /api is open on port 80;
  - nothing is deleted here: a cancelled invoice's photos stay its evidence;
  - the folder goes into the backup's zip and comes back with it.
"""
from __future__ import annotations

import hashlib
import os
import struct
from typing import NamedTuple, Optional

from models import Attachment, db

MAX_BYTES = 2_000_000              # a 1600 px JPEG at 80 is far below
MAX_SIDE = 2048                    # the device sends 1600
MAX_PER_RECORD = 10                # the owner, 17 Nov 2026
SCRAP_GOLD_PHOTO = 'scrap_gold_photo'
MODEL_PHOTO = 'model_photo'             # a piece model's photo and its thumbnail (ADR-093 §7)
MODEL_THUMBNAIL = 'model_thumbnail'
INVOICE = 'invoice'
PIECE_MODEL = 'piece_model'
# Each kind its right to send it and to see it: a scrap purchase's photos are
# the invoices', a model's the items'.
ROLE_RIGHTS = {
    SCRAP_GOLD_PHOTO: ('invoices.create', 'invoices.view'),
    MODEL_PHOTO: ('items.edit', 'items.view'),
    MODEL_THUMBNAIL: ('items.edit', 'items.view'),
}
_EXT = {'jpeg': 'jpg', 'png': 'png', 'webp': 'webp'}
_MIME = {'jpeg': 'image/jpeg', 'png': 'image/png', 'webp': 'image/webp'}


class AttachmentRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def media_root() -> str:
    """Where the files live: MEDIA_ROOT, else a folder beside the code -- in
    development only. In production a photo kept inside the container is lost
    on its next update: without MEDIA_ROOT nothing is kept (AttachmentRefused)."""
    root = (os.environ.get('MEDIA_ROOT') or '').strip()
    if root:
        return root
    if (os.environ.get('YASAR_ENV') or '').strip().lower() == 'production':
        raise AttachmentRefused('media_root_not_set',
                                'مجلد الصور غير مضبوط على الخادم (MEDIA_ROOT): لا تُحفظ صورة حتى يُضبط')
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'media_data')


class Image(NamedTuple):
    kind: str
    width: Optional[int]
    height: Optional[int]


def _jpeg_size(raw: bytes):
    i = 2
    while i + 9 < len(raw):
        if raw[i] != 0xFF:
            i += 1
            continue
        marker = raw[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = struct.unpack('>H', raw[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            height, width = struct.unpack('>HH', raw[i + 5:i + 9])
            return width, height
        i += 2 + length
    return None, None


def _webp_size(raw: bytes):
    chunk = raw[12:16]
    if chunk == b'VP8X' and len(raw) >= 30:
        return 1 + int.from_bytes(raw[24:27], 'little'), 1 + int.from_bytes(raw[27:30], 'little')
    if chunk == b'VP8 ' and len(raw) >= 30:
        w, h = struct.unpack('<HH', raw[26:30])
        return w & 0x3FFF, h & 0x3FFF
    if chunk == b'VP8L' and len(raw) >= 25:
        b = raw[21:25]
        return 1 + (((b[1] & 0x3F) << 8) | b[0]), 1 + (((b[3] & 0xF) << 10) | (b[2] << 2) | ((b[1] & 0xC0) >> 6))
    return None, None


def read_image(raw: bytes) -> Image:
    """The image *raw* is by its own first bytes -- or AttachmentRefused."""
    if raw[:3] == b'\xff\xd8\xff':
        kind, (w, h) = 'jpeg', _jpeg_size(raw)
    elif raw[:8] == b'\x89PNG\r\n\x1a\n' and len(raw) >= 24:
        kind, (w, h) = 'png', struct.unpack('>II', raw[16:24])
    elif raw[:4] == b'RIFF' and raw[8:12] == b'WEBP':
        kind, (w, h) = 'webp', _webp_size(raw)
    else:
        raise AttachmentRefused('attachment_not_an_image', 'الملف ليس صورة JPEG أو PNG أو WebP')
    return Image(kind, w, h)


def _path(sha: str, kind: str) -> str:
    return os.path.join(media_root(), sha[:2], f'{sha}.{_EXT[kind]}')


def store(raw: bytes, *, role: str, by: str, now) -> Attachment:
    """A photo sent: its file kept once by its fingerprint, its row pending
    under its sender. The caller commits."""
    if not raw:
        raise AttachmentRefused('attachment_empty', 'الملف فارغ')
    if len(raw) > MAX_BYTES:
        raise AttachmentRefused('attachment_too_large',
                                f'الصورة {len(raw) // 1000} ك.ب، والحد {MAX_BYTES // 1000} ك.ب')
    image = read_image(raw)
    if (image.width or 0) > MAX_SIDE or (image.height or 0) > MAX_SIDE:
        raise AttachmentRefused('attachment_too_large', f'الصورة أكبر من {MAX_SIDE} بكسل: صغّرها أولًا')
    sha = hashlib.sha256(raw).hexdigest()
    path = _path(sha, image.kind)
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        part = f'{path}.part-{os.getpid()}'
        with open(part, 'wb') as out:
            out.write(raw)
        os.replace(part, path)                 # whole or not at all
    row = Attachment(sha256=sha, kind=image.kind, bytes=len(raw), width=image.width, height=image.height,
                     role=role, uploaded_by=by, uploaded_at=now)
    db.session.add(row)
    db.session.flush()
    return row


def _ids(ids) -> list:
    try:
        found = [int(i) for i in ids or ()]
    except (TypeError, ValueError):
        raise AttachmentRefused('attachment_not_found', 'رقم صورة غير مفهوم') from None
    if len(set(found)) != len(found):
        raise AttachmentRefused('attachment_repeated', 'الصورة مذكورة مرتين')
    return found


def check_linkable(ids, *, role: str, by: str) -> list:
    """The photos an invoice is saved with: each its sender's, pending, of the
    role, at most MAX_PER_RECORD -- or AttachmentRefused, nothing written."""
    wanted = _ids(ids)
    if len(wanted) > MAX_PER_RECORD:
        raise AttachmentRefused('attachments_too_many', f'{MAX_PER_RECORD} صور على الأكثر')
    rows = {a.id: a for a in Attachment.query.filter(Attachment.id.in_(wanted or [-1]))}
    for i in wanted:
        row = rows.get(i)
        if row is None or row.role != role:
            raise AttachmentRefused('attachment_not_found', f'الصورة {i} غير موجودة')
        if row.uploaded_by != by:
            raise AttachmentRefused('attachment_not_yours', f'الصورة {i} أرسلها مستخدم آخر')
        if row.entity_id is not None:
            raise AttachmentRefused('attachment_already_linked', f'الصورة {i} مربوطة بسجل آخر')
    return [rows[i] for i in wanted]


def link(ids, *, entity_type: str, entity_id: int, role: str, by: str, now) -> list:
    """The photos linked to their record, in the caller's transaction; each
    row locked, so two saves cannot take one photo."""
    rows = check_linkable(ids, role=role, by=by)
    for row in Attachment.query.filter(Attachment.id.in_([r.id for r in rows] or [-1])).with_for_update():
        if row.entity_id is not None:
            raise AttachmentRefused('attachment_already_linked', f'الصورة {row.id} مربوطة بسجل آخر')
        row.entity_type, row.entity_id, row.linked_at = entity_type, int(entity_id), now
    db.session.flush()
    return rows


def view(row: Attachment) -> dict:
    return {'id': row.id, 'kind': row.kind, 'bytes': row.bytes, 'width': row.width, 'height': row.height,
            'role': row.role, 'entity_type': row.entity_type, 'entity_id': row.entity_id,
            'uploaded_by': row.uploaded_by, 'uploaded_at': row.uploaded_at.isoformat() if row.uploaded_at else None}


def of_record(entity_type: str, entity_id: int) -> list:
    return [view(a) for a in Attachment.query.filter_by(entity_type=entity_type, entity_id=int(entity_id))
            .order_by(Attachment.id).all()]


def file_of(row: Attachment) -> tuple[str, str]:
    """(its path, its mime type) -- or AttachmentRefused when the file is gone."""
    path = _path(row.sha256, row.kind)
    if not os.path.exists(path):
        raise AttachmentRefused('attachment_file_missing', 'ملف الصورة غير موجود على الخادم')
    return path, _MIME[row.kind]


# ── the backup (ADR-094 §7) ─────────────────────────────────────────────────

MEDIA_IN_ZIP = 'media/'


def add_media_to_zip(zf) -> int:
    """Every file of the media folder into the backup's zip, under media/."""
    try:
        root = media_root()
    except AttachmentRefused:
        return 0                               # no folder, no photos: the books are still backed up
    count = 0
    if not os.path.isdir(root):
        return 0
    for folder, _, files in os.walk(root):
        for name in files:
            if '.part-' in name:
                continue
            path = os.path.join(folder, name)
            zf.write(path, arcname=MEDIA_IN_ZIP + os.path.relpath(path, root).replace(os.sep, '/'))
            count += 1
    return count


def restore_media_from_zip(zf) -> int:
    """The backup's media files back into the folder: a file kept by its
    fingerprint is the same file, so what is there stays and what is missing
    is written. A name that leaves the folder is refused."""
    root = os.path.realpath(media_root())
    count = 0
    for member in zf.namelist():
        if not member.startswith(MEDIA_IN_ZIP) or member.endswith('/'):
            continue
        target = os.path.realpath(os.path.join(root, member[len(MEDIA_IN_ZIP):]))
        if not target.startswith(root + os.sep):
            raise AttachmentRefused('backup_media_path_invalid', f'مسار غير مقبول في النسخة: {member}')
        if os.path.exists(target):
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with zf.open(member) as src, open(target + '.part', 'wb') as out:
            out.write(src.read())
        os.replace(target + '.part', target)
        count += 1
    return count
