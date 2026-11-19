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


def test_a_label_writes_the_tag_reads_it_back_and_prints_the_number():
    zpl = z.label_zpl('KJ-000001', karat='21', weight=12.4)
    assert zpl.startswith('^XA') and zpl.rstrip().endswith('^XZ')
    assert '^RFW,H,,,A^FD4B4A00000000000000000001^FS' in zpl
    assert '^RFR,H' in zpl and '^HV1,24,EPC=' in zpl, 'read back to the host'
    assert '^BXN' in zpl and '^FDKJ-000001^FS' in zpl, 'the DataMatrix the counter scans'
    assert '21K · 12.40g' in zpl


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
