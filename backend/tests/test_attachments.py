"""A photo is a file on the server's disk, its record here (ADR-094; the owner, 17 Nov 2026).

«صور الذهب في شراء الكسر لا تُحفظ إطلاقًا»: the screen sent their count
only. The laws:
  - a photo is an image by its own first bytes, within its size and side;
    named by its content's fingerprint, kept once;
  - it waits under its sender; a customer's scrap purchase saved with it
    links it in its own transaction -- by its sender only, once, ten at most;
    refused, the invoice is not written;
  - it is read through the server with the right to see invoices; a pending
    one by its sender alone;
  - the backup's zip carries the folder and the restore brings it back.

Run:
    python -m pytest tests/test_attachments.py -v
"""
import datetime as dt
import io
import os
import struct
import zipfile

import pytest
from flask import g

from models import Attachment, Invoice, db
from services.attachments import (MAX_PER_RECORD, SCRAP_GOLD_PHOTO, AttachmentRefused, add_media_to_zip,
                                  check_linkable, media_root, read_image, restore_media_from_zip, store)
from tests.retraction_world import world  # noqa: F401 (fixture)

NOW = dt.datetime(2026, 11, 17, 18, 0)


def jpeg(width=1600, height=1200, salt=b''):
    """A JPEG's first bytes as a camera writes them: SOI, a frame header, data."""
    sof = b'\xff\xc0' + struct.pack('>HBHHB', 17, 8, height, width, 3) + b'\x01\x22\x00\x02\x11\x01\x03\x11\x01'
    return b'\xff\xd8' + sof + b'\xff\xda' + b'\x00' * 64 + salt + b'\xff\xd9'


def png(width=800, height=600):
    return b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', width, height) + b'\x08\x02\x00\x00\x00'


@pytest.fixture(scope='module')
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence, tmp_path, monkeypatch):
    monkeypatch.setenv('MEDIA_ROOT', str(tmp_path / 'media'))
    yield


def _client():
    from app import app as flask_app
    g.pop('current_user', None)
    return flask_app.test_client()


def _upload(auth_headers, raw, role=SCRAP_GOLD_PHOTO):
    return _client().post('/api/attachments', headers=auth_headers, content_type='multipart/form-data',
                          data={'role': role, 'file': (io.BytesIO(raw), 'gold.jpg')})


def _scrap_purchase(world, **extra):
    return {'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
            'transaction_type': 'buy', 'employee_id': world['holder'].id,
            'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
            'date': '2031-04-11T10:00:00', 'total': 100.0, 'total_weight': 1.0, 'total_cost': 100.0,
            'total_tax': 0.0, 'amount_paid': 100.0,
            'payments': [{'payment_method_id': world['pm'].id, 'amount': 100.0}],
            'items': [{'name': 'كسر', 'karat': 21, 'weight': 1.0, 'standing_weight': 1.0, 'stones_weight': 0.0,
                       'price': 100.0, 'net': 100.0, 'quantity': 1}], **extra}


def test_a_photo_is_an_image_by_its_bytes_kept_once_by_its_fingerprint():
    assert read_image(jpeg(1600, 1200)) == ('jpeg', 1600, 1200)
    assert read_image(png(800, 600)) == ('png', 800, 600)
    a = store(jpeg(), role=SCRAP_GOLD_PHOTO, by='t', now=NOW)
    b = store(jpeg(), role=SCRAP_GOLD_PHOTO, by='t', now=NOW)
    assert a.id != b.id and a.sha256 == b.sha256 and (a.width, a.height) == (1600, 1200)
    files = [f for _, _, fs in os.walk(media_root()) for f in fs]
    assert files == [f'{a.sha256}.jpg'], 'one file for one content'
    for raw, code in ((b'<svg onload=1>', 'attachment_not_an_image'), (b'', 'attachment_empty'),
                      (jpeg(4000, 3000), 'attachment_too_large'),
                      (jpeg(salt=b'\x00' * 2_100_000), 'attachment_too_large')):
        with pytest.raises(AttachmentRefused) as refused:
            store(raw, role=SCRAP_GOLD_PHOTO, by='t', now=NOW)
        assert refused.value.code == code


def test_linked_by_its_sender_only_once_ten_at_most():
    mine = store(jpeg(salt=b'1'), role=SCRAP_GOLD_PHOTO, by='t', now=NOW)
    theirs = store(jpeg(salt=b'2'), role=SCRAP_GOLD_PHOTO, by='other', now=NOW)

    def code(ids, by='t'):
        with pytest.raises(AttachmentRefused) as refused:
            check_linkable(ids, role=SCRAP_GOLD_PHOTO, by=by)
        return refused.value.code
    assert code([theirs.id]) == 'attachment_not_yours'
    assert code([mine.id, mine.id]) == 'attachment_repeated'
    assert code([999999]) == 'attachment_not_found'
    many = [store(jpeg(salt=bytes([i])), role=SCRAP_GOLD_PHOTO, by='t', now=NOW).id for i in range(MAX_PER_RECORD + 1)]
    assert code(many) == 'attachments_too_many'
    mine.entity_type, mine.entity_id = 'invoice', 1
    db.session.flush()
    assert code([mine.id]) == 'attachment_already_linked'


def test_a_scrap_purchase_saved_with_its_photos_links_them_and_a_refused_one_writes_nothing(auth_headers, world):
    first = _upload(auth_headers, jpeg(salt=b'a'))
    second = _upload(auth_headers, png())
    assert first.status_code == 201, first.get_data(as_text=True)[:300]
    ids = [first.get_json()['id'], second.get_json()['id']]
    saved = _client().post('/api/invoices', headers=auth_headers, json=_scrap_purchase(world, attachment_ids=ids))
    assert saved.status_code == 201, saved.get_data(as_text=True)[:300]
    invoice_id = saved.get_json()['id']
    listed = _client().get(f'/api/invoices/{invoice_id}/attachments', headers=auth_headers).get_json()
    assert [a['id'] for a in listed] == ids and {a['entity_id'] for a in listed} == {invoice_id}
    before = Invoice.query.count()
    again = _client().post('/api/invoices', headers=auth_headers, json=_scrap_purchase(world, attachment_ids=ids[:1]))
    assert again.status_code == 400 and again.get_json()['error'] == 'attachment_already_linked'
    other = store(jpeg(salt=b'b'), role=SCRAP_GOLD_PHOTO, by='someone_else', now=NOW)
    foreign = _client().post('/api/invoices', headers=auth_headers,
                             json=_scrap_purchase(world, attachment_ids=[other.id]))
    assert foreign.status_code == 400 and foreign.get_json()['error'] == 'attachment_not_yours'
    assert Invoice.query.count() == before, 'refused, no invoice written'
    sale = _client().post('/api/invoices', headers=auth_headers,
                          json={**_scrap_purchase(world), 'invoice_type': 'بيع', 'gold_type': 'new',
                                'attachment_ids': [_upload(auth_headers, jpeg(salt=b'c')).get_json()['id']]})
    assert sale.status_code == 400 and sale.get_json()['error'] == 'attachments_not_allowed'


def test_read_through_the_server_a_pending_one_by_its_sender_alone(auth_headers):
    raw = jpeg(salt=b'r')
    sent = _upload(auth_headers, raw).get_json()
    read = _client().get(f"/api/attachments/{sent['id']}", headers=auth_headers)
    assert read.status_code == 200 and read.data == raw and read.mimetype == 'image/jpeg'
    assert read.headers['Cache-Control'] == 'private, max-age=86400'
    hidden = store(jpeg(salt=b'h'), role=SCRAP_GOLD_PHOTO, by='someone_else', now=NOW)
    assert _client().get(f'/api/attachments/{hidden.id}', headers=auth_headers).status_code == 404
    assert _client().get(f"/api/attachments/{sent['id']}").status_code == 401, 'no token, no photo'
    refused = _upload(auth_headers, b'not a photo')
    assert refused.status_code == 400 and refused.get_json()['error'] == 'attachment_not_an_image'


def test_the_backup_carries_the_photos_and_the_restore_brings_them_back(tmp_path):
    row = store(jpeg(salt=b'z'), role=SCRAP_GOLD_PHOTO, by='t', now=NOW)
    path = os.path.join(media_root(), row.sha256[:2], f'{row.sha256}.jpg')
    kept = open(path, 'rb').read()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as zf:
        assert add_media_to_zip(zf) == 1
    os.remove(path)
    with zipfile.ZipFile(io.BytesIO(buffer.getvalue())) as zf:
        assert zf.namelist() == [f'media/{row.sha256[:2]}/{row.sha256}.jpg']
        assert restore_media_from_zip(zf) == 1
    assert open(path, 'rb').read() == kept
    evil = io.BytesIO()
    with zipfile.ZipFile(evil, 'w') as zf:
        zf.writestr('media/../../escaped.txt', b'x')
    with zipfile.ZipFile(io.BytesIO(evil.getvalue())) as zf, pytest.raises(AttachmentRefused):
        restore_media_from_zip(zf)


def test_the_backup_routes_put_the_photos_in_the_zip(auth_headers, monkeypatch):
    """The download writes them, as the scheduler and the snapshot do -- one helper."""
    import routes.system as system
    store(jpeg(salt=b'd'), role=SCRAP_GOLD_PHOTO, by='t', now=NOW)
    monkeypatch.setattr(system, '_is_postgres_database', lambda: True)
    monkeypatch.setattr(system, '_create_postgres_backup_to_file', lambda path: open(path, 'wb').write(b'dump'))
    reply = _client().get('/api/system/backup/download', headers=auth_headers)
    assert reply.status_code == 200, reply.get_data(as_text=True)[:200]
    names = zipfile.ZipFile(io.BytesIO(reply.data)).namelist()
    assert 'database.dump' in names and any(n.startswith('media/') for n in names)


def test_the_night_says_a_photo_left_pending_by_the_books_clock(world):
    from models import JournalEntry
    from services.books_invariants import ATTACHMENT_LEFT_PENDING, check_attachments_left_pending
    db.session.add(JournalEntry(entry_number='JE-ATT-CLOCK', date=dt.datetime(2099, 6, 1, 12), description='الساعة',
                                entry_type='عادي', is_posted=True, is_draft=False, created_by='t'))
    db.session.flush()
    last = db.session.query(db.func.max(JournalEntry.date)).filter(JournalEntry.is_posted.is_(True)).scalar()
    old = store(jpeg(salt=b'old'), role=SCRAP_GOLD_PHOTO, by='t', now=last - dt.timedelta(days=3))
    fresh = store(jpeg(salt=b'new'), role=SCRAP_GOLD_PHOTO, by='t', now=last)
    linked = store(jpeg(salt=b'lnk'), role=SCRAP_GOLD_PHOTO, by='t', now=last - dt.timedelta(days=3))
    linked.entity_type, linked.entity_id = 'invoice', 1
    db.session.flush()
    found = {f.subject_key: f for f in check_attachments_left_pending()}
    assert f'attachment:{old.id}' in found and found[f'attachment:{old.id}'].kind == ATTACHMENT_LEFT_PENDING
    assert f'attachment:{fresh.id}' not in found and f'attachment:{linked.id}' not in found


def test_in_production_without_its_folder_no_photo_is_kept_and_the_backup_still_runs(monkeypatch):
    monkeypatch.delenv('MEDIA_ROOT', raising=False)
    monkeypatch.setenv('YASAR_ENV', 'production')
    with pytest.raises(AttachmentRefused) as refused:
        store(jpeg(salt=b'p'), role=SCRAP_GOLD_PHOTO, by='t', now=NOW)
    assert refused.value.code == 'media_root_not_set'
    with zipfile.ZipFile(io.BytesIO(), 'w') as zf:
        assert add_media_to_zip(zf) == 0
