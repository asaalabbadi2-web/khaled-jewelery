"""The printers' setup and a label's preview (ADR-097 ط5; the owner, 20 Nov 2026).

- A label's preview says what its faces print -- one source, the long name
  cut with «…» the same.
- A test label prints its faces only: no tag written, none read, none recorded.
- The manager keeps the printers (system.settings): its address, on or off,
  its font installed and read back from its listing, a calibration, a test
  label -- «لا تردّ» when it does not answer.

Run:
    python -m pytest tests/test_label_setup.py -v
"""
import socket
import threading
from datetime import date

import pytest

from models import LabelPrinter, PieceModel, Settings, db
from services import piece_label as L
from tests.test_piece_tag import _pieces
from tests.test_print_engine import READY, _printer
from tests.test_stock_count import NOW


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    Settings.query.first().receiving_from = date(2026, 1, 1)
    db.session.flush()
    yield


class Printer:
    """A printer on a local port: its status, its flash's listing, what it was sent."""

    def __init__(self, ready=READY):
        self.ready, self.received = ready, []
        self.server = socket.socket()
        self.server.bind(('127.0.0.1', 0))
        self.server.listen(8)
        self.port = self.server.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                conn.settimeout(1.0)
                data = b''
                try:
                    while True:
                        chunk = conn.recv(262144)
                        if not chunk:
                            break
                        data += chunk
                        if data.endswith(b'^XZ\n') or data.endswith(b'~HS\n') or b'^HR^XZ' in data:
                            break
                except socket.timeout:
                    pass
                text = data.decode('latin-1')
                self.received.append(text)
                if '~HS' in text:
                    conn.sendall(self.ready.encode())
                elif '^HW' in text:
                    conn.sendall(b'- DIR E:CAIRO.* \r\n* E:CAIRO.TTF    164632\r\n')

    def close(self):
        # shutdown before close (21 Nov 2026): on Linux a close alone leaves the
        # thread blocked in accept() with the port still listening -- it went on
        # answering READY in CI; on macOS the close alone stops it
        try:
            self.server.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.server.close()
        self.thread.join(timeout=2)


def _client(auth_headers):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    g.pop('current_user', None)
    return flask_app.test_client()


# ── the preview ──────────────────────────────────────────────────────────────

def test_the_preview_says_what_the_label_prints():
    long_name = 'طقم ذهب إيطالي مرصع بفصوص زركون ملونة كبير'
    long_brand = 'مجوهرات خالد للذهب والألماس والساعات الفاخرة في المملكة'
    facts = dict(karat='21', weight=12.4, name=long_name, stones=0.35, size='18', brand=long_brand)
    faces = L.label_faces('KJ-000124', **facts)
    assert (faces['code'], faces['code_type'], faces['number'], faces['weight'], faces['karat'], faces['stones'],
            faces['size']) == ('KJ-000124', 'datamatrix', 'KJ-000124', '12.40g', '21K', 'St 0.35g', 'Sz 18')
    assert 'facts' not in faces, 'the weight and the karat each a line of its own'
    assert faces['name'].endswith('…') and len(faces['name']) < len(long_name), 'cut as the label cuts it'
    assert faces['brand'].endswith('…'), 'the shop\'s name cut as the label cuts it'
    zpl = L.label_zpl('KJ-000124', **facts)
    for said in (faces['name'], faces['brand']):
        assert f'^FD{L.shaped(said)}^FS' in zpl, 'the preview\'s words are the printed ones'
    for said in (faces['karat'], faces['stones'], faces['size'], faces['number']):
        assert f'^FD{said}^FS' in zpl
    assert '^FD12.40^FS' in zpl and '^FDg^FS' in zpl, 'the weight, its «g» smaller after it'


def test_a_pieces_preview_names_its_model_else_its_category(auth_headers):
    [piece] = _pieces(10.0)
    r = _client(auth_headers).get(f'/api/pieces/{piece.id}/label-preview', headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    faces = r.get_json()['faces']
    assert faces['name'].startswith('بنجرة رقاقة') and faces['number'] == piece.item_code, 'its category\'s'
    model = PieceModel(category_id=piece.category_id, name='بنجرة الشمس', created_by='t', created_at=NOW)
    db.session.add(model)
    db.session.flush()
    piece.model_id = model.id
    db.session.flush()
    again = _client(auth_headers).get(f'/api/pieces/{piece.id}/label-preview', headers=auth_headers).get_json()
    assert again['faces']['name'] == 'بنجرة الشمس', 'its model\'s'


def test_a_test_label_writes_no_tag():
    zpl = L.label_zpl('KJ-999999', karat='21', weight=12.4, name='بطاقة تجربة', write_tag=False)
    assert '^RFW' not in zpl and '^RFR' not in zpl and '^HV' not in zpl
    assert '^BXN' in zpl and '^FDKJ-999999^FS' in zpl, 'its faces as any label\'s'


# ── the printers ─────────────────────────────────────────────────────────────

def test_the_manager_keeps_a_printer(auth_headers):
    printer = _printer()
    client = _client(auth_headers)
    r = client.patch(f'/api/label-printers/{printer.id}', headers=auth_headers,
                     json={'host': '192.168.254.254', 'is_active': False})
    assert r.status_code == 200 and (r.get_json()['printer']['host'], r.get_json()['printer']['is_active']) == \
        ('192.168.254.254', False)
    assert client.patch(f'/api/label-printers/{printer.id}', headers=auth_headers,
                        json={'host': '  '}).status_code == 400


def test_its_font_its_calibration_and_its_test_label(auth_headers):
    printer = _printer()
    device = Printer()
    try:
        printer.host, printer.port = '127.0.0.1', device.port
        db.session.flush()
        client = _client(auth_headers)
        font = client.post(f'/api/label-printers/{printer.id}/install-font', headers=auth_headers)
        assert font.status_code == 200 and font.get_json()['message'] == 'الخط في ذاكرة الطابعة'
        assert db.session.get(LabelPrinter, printer.id).font_installed_at is not None, 'read back, then recorded'
        assert any(t.startswith('~DYE:CAIRO,B,T,') for t in device.received)
        cal = client.post(f'/api/label-printers/{printer.id}/calibrate', headers=auth_headers)
        assert cal.status_code == 200 and any('~JC' in t for t in device.received)
        test = client.post(f'/api/label-printers/{printer.id}/test-label', headers=auth_headers)
        assert test.status_code == 200 and 'بلا رقاقة' in test.get_json()['message']
        sent = [t for t in device.received if '^BXN' in t]
        assert sent and '^RFW' not in sent[-1], 'its faces only'
    finally:
        device.close()
    gone = _client(auth_headers).post(f'/api/label-printers/{printer.id}/test-label', headers=auth_headers)
    assert gone.status_code == 400 and 'لا تردّ' in gone.get_json()['message']


def test_a_test_label_waits_for_a_ready_printer(auth_headers):
    printer = _printer()
    device = Printer(ready=READY.replace('030,0,0,0336', '030,1,0,0336'))
    try:
        printer.host, printer.port = '127.0.0.1', device.port
        db.session.flush()
        r = _client(auth_headers).post(f'/api/label-printers/{printer.id}/test-label', headers=auth_headers)
        assert r.get_json()['message'] == 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'
        assert not [t for t in device.received if '^BXN' in t], 'nothing printed'
    finally:
        device.close()


def test_the_printers_setup_is_the_managers():
    """Its writes ask system.settings -- not a coder's items.create."""
    import inspect
    from routes import pieces as routes
    source = inspect.getsource(routes)
    for path in ("/label-printers', methods=['POST']", "/label-printers/<int:printer_id>', methods=['PATCH']",
                 "/install-font'", "/calibrate'", "/test-label'"):
        block = source[source.index(path):source.index(path) + 200]
        assert "require_permission('system.settings')" in block, path


class Forgetful(Printer):
    """A printer that takes what it is sent and lists nothing back."""

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                conn.settimeout(1.0)
                try:
                    while conn.recv(262144):
                        pass
                except socket.timeout:
                    pass


def test_a_font_not_in_the_listing_is_not_recorded(auth_headers):
    printer = _printer()
    device = Forgetful()
    try:
        printer.host, printer.port = '127.0.0.1', device.port
        db.session.flush()
        r = _client(auth_headers).post(f'/api/label-printers/{printer.id}/install-font', headers=auth_headers)
        assert 'لم يظهر' in r.get_json()['message']
        assert db.session.get(LabelPrinter, printer.id).font_installed_at is None, 'not recorded on its word alone'
    finally:
        device.close()


# ── the code's kind (the owner, 27 Nov 2026: «اعداد لتحديد اي رمز يطبع QR, DM, BC وغيرها») ─────────────

def _patch_settings(auth_headers, changes):
    client = _client(auth_headers)
    seen = client.get('/api/settings/versions', headers=auth_headers).get_json()['versions']
    from flask import g
    g.pop('current_user', None)
    return client.patch('/api/settings', headers=auth_headers, json={
        'changes': changes, 'versions': {k: seen.get(k, 0) for k in changes}, 'reason': 'نوع رمز البطاقة'})


def test_the_labels_code_is_the_settings_read_at_each_print(auth_headers):
    from services.label_printing import _label, label_facts
    [piece] = _pieces(10.0)
    assert label_facts(piece)['code_type'] == 'datamatrix', 'nothing chosen: what was printed before'
    assert '^BXN' in _label(piece, L.epc_of(piece.item_code))
    Settings.query.first().piece_label_code = 'qr'
    db.session.flush()
    printed = _label(piece, L.epc_of(piece.item_code))
    assert '^BQN,2,4^FDMA,' in printed and '^BXN' not in printed, 'read at the print, not kept from before'
    faces = _client(auth_headers).get(f'/api/pieces/{piece.id}/label-preview', headers=auth_headers).get_json()['faces']
    assert faces['code_type'] == 'qr', 'the preview draws the code the label prints'


def test_the_shops_name_is_the_settings_read_at_each_print(auth_headers):
    """The owner, 27 Nov 2026: «ليس بقيم ثابتة بل ديناميكيه مثل اسم المحل» -- the company's name in the
    settings, read at each print (live, §13) as the code's kind is; a label printed keeps its own."""
    from services.label_printing import _label, label_facts
    [piece] = _pieces(10.0)
    settings = Settings.query.first()
    settings.company_name = 'مجوهرات الاختبار'
    db.session.flush()
    assert label_facts(piece)['brand'] == 'مجوهرات الاختبار'
    assert f'^FD{L.shaped("مجوهرات الاختبار")}^FS' in _label(piece, L.epc_of(piece.item_code))
    settings.company_name = 'ذهب الشمال'
    db.session.flush()
    assert f'^FD{L.shaped("ذهب الشمال")}^FS' in _label(piece, L.epc_of(piece.item_code)), 'read at the print'
    faces = _client(auth_headers).get(f'/api/pieces/{piece.id}/label-preview', headers=auth_headers).get_json()['faces']
    assert faces['brand'] == 'ذهب الشمال', 'the preview says the name the label prints'
    settings.company_name = ''
    db.session.flush()
    assert label_facts(piece)['brand'] is None
    assert L.shaped('ذهب الشمال') not in _label(piece, L.epc_of(piece.item_code)), 'none set: no line'


def test_a_test_label_carries_the_shops_name(auth_headers):
    printer = _printer()
    device = Printer()
    try:
        printer.host, printer.port = '127.0.0.1', device.port
        Settings.query.first().company_name = 'ذهب الشمال'
        db.session.flush()
        r = _client(auth_headers).post(f'/api/label-printers/{printer.id}/test-label', headers=auth_headers)
        assert r.status_code == 200, r.get_data(as_text=True)
        sent = [t.encode('latin-1').decode('utf-8') for t in device.received if '^BXN' in t]
        assert sent and f'^FD{L.shaped("ذهب الشمال")}^FS' in sent[-1], 'as a piece\'s label prints it'
    finally:
        device.close()


def test_the_code_is_chosen_among_the_four_through_the_settings(auth_headers):
    from services.settings_policy import level
    assert level('piece_label_code') == 2, 'it changes how a document is made'
    assert _client(auth_headers).get('/api/settings', headers=auth_headers).get_json()['piece_label_code'] \
        == Settings.query.first().piece_label_code
    saved = _patch_settings(auth_headers, {'piece_label_code': 'code128'})
    assert saved.status_code == 200, saved.get_data(as_text=True)
    assert Settings.query.first().piece_label_code == 'code128'
    for wrong in ('code39', '', None):
        refused = _patch_settings(auth_headers, {'piece_label_code': wrong})
        assert refused.status_code == 400 and refused.get_json()['error'] == 'invalid_piece_label_code', wrong
    assert Settings.query.first().piece_label_code == 'code128', 'nothing changed by a refusal'


def test_a_test_label_in_the_code_chosen_framed_with_the_chips_bump(auth_headers):
    printer = _printer()
    device = Printer()
    try:
        printer.host, printer.port = '127.0.0.1', device.port
        Settings.query.first().piece_label_code = 'code128'
        db.session.flush()
        r = _client(auth_headers).post(f'/api/label-printers/{printer.id}/test-label', headers=auth_headers,
                                       json={'frame': True})
        assert r.status_code == 200, r.get_data(as_text=True)
        sent = [t for t in device.received if '^BCN' in t]
        assert sent and '^RFW' not in sent[-1], 'its faces only, in Code 128'
        assert f'^GB{L.FACE_W},{2 * L.BUMP_R},1^FS' in sent[-1], 'the bump drawn, to be checked on the tag'
    finally:
        device.close()
