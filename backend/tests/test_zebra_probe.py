"""The printer's test tool (ADR-085 ت0): its tag value is the system's, and a tag is taken only as read back.

Run:
    python -m pytest tests/test_zebra_probe.py -v
"""
import socket
import threading

import pytest

from services.pieces import EPC_PREFIX, epc_of as system_epc
from tools.hardware import zebra_probe as z


@pytest.mark.parametrize('number', ['KJ-000001', 'KJ-000124', 'KJ-1234567'])
def test_its_tag_value_is_the_systems(number):
    assert z.EPC_PREFIX == EPC_PREFIX
    assert z.epc_of(number) == system_epc(number)


def test_only_our_numbers():
    for bad in ('KJ-12', 'AB-000001', '', None):
        with pytest.raises(ValueError):
            z.epc_of(bad)


def test_its_label_is_the_systems_one_design():
    from services import piece_label
    assert z.label_zpl is piece_label.label_zpl, 'one design: the probe prints the system\'s label'


def test_the_font_is_kept_on_the_printer_once():
    head = z.font_upload()[:40]
    assert head.startswith(b'~DYE:CAIRO,B,T,') and z.FONT_ON_PRINTER == 'E:CAIRO.TTF'


def test_the_reply_is_read_for_the_value():
    assert z.read_back('EPC=4B4A00000000000000000001\r\n') == '4B4A00000000000000000001'
    assert z.read_back('') is None
    assert z.read_back('EPC=') is None


def test_sent_to_a_printer_and_its_answer_compared():
    """A printer on a socket: answers the value it read; the tool says ✓ only when it is the one sent."""
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    port = server.getsockname()[1]
    got = {}

    def printer(answer):
        conn, _ = server.accept()
        got['zpl'] = conn.recv(65536).decode()
        conn.sendall(answer.encode())
        conn.close()

    for answer, code in (('EPC=4B4A00000000000000000001', 0), ('EPC=4B4A00000000000000000002', 1)):
        t = threading.Thread(target=printer, args=(answer,))
        t.start()
        z.PORT, saved = port, z.PORT
        try:
            assert z.main(['--host', '127.0.0.1', '--number', 'KJ-000001']) == code
        finally:
            z.PORT = saved
        t.join()
        assert '^RFW' in got['zpl']
    server.close()

