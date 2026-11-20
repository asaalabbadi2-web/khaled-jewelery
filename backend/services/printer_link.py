"""Talking to a Zebra label printer on the network (ADR-085, ADR-097 ط2): ZPL on its port, its status, the tag read back.

The one link: the print engine (services/label_printing) and the probe
(tools/hardware/zebra_probe.py) both talk through it. It writes no row and
reads no database.

- status(): ~HS, read as what stops a label -- out of labels, out of ribbon,
  the head open, paused -- or ready; PrinterUnreachable when it does not answer.
- send(): a label sent, its answer read until the tag's value comes back.
  Nothing sent (no connection) is PrinterUnreachable -- certain; the line
  dropped after sending is LinkLost -- the end unknown (ADR-097 law 10).
"""
from __future__ import annotations

import re
import socket

PORT = 9100
HEX24 = re.compile(r'[0-9A-F]{24}')
STATUS = '~HS\n'


class PrinterUnreachable(OSError):
    """No connection: nothing was sent."""


class LinkLost(OSError):
    """Sent, and the line dropped before its answer: what the printer did is not known."""


def read_back(reply: str):
    """The value the printer read back from the tag (^HV), or None."""
    match = HEX24.search(str(reply or '').upper().split('EPC=', 1)[-1])
    return match.group(0) if match else None


def answered_empty(reply: str) -> bool:
    """The printer answered its read back with no value: the tag was not written -- certain."""
    return 'EPC=' in str(reply or '').upper() and read_back(reply) is None


STOPS = (
    ('paper_out', 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'),
    ('ribbon_out', 'انتهى الشريط: ركّب شريطًا جديدًا ثم أعد المحاولة'),
    ('head_open', 'غطاء الطابعة مفتوح: أغلقه ثم أعد المحاولة'),
    ('paused', 'الطابعة موقوفة مؤقتًا: اضغط زر الإيقاف فيها ثم أعد المحاولة'),
)
UNREACHABLE = 'الطابعة لا تردّ: تأكد أنها مشغّلة وعلى الشبكة ثم أعد المحاولة'


def parse_status(reply: str) -> dict:
    """~HS's three strings, read: {'ready', 'stops': [codes], 'message'}."""
    rows = [r.strip('\x02\x03\r\n ') for r in str(reply or '').replace('\x03', '\n').split('\n')]
    rows = [r.split(',') for r in rows if r]
    if len(rows) < 2 or len(rows[0]) < 3 or len(rows[1]) < 4:
        raise PrinterUnreachable('status not understood')
    flags = {'paper_out': rows[0][1] == '1', 'paused': rows[0][2] == '1',
             'head_open': rows[1][2] == '1', 'ribbon_out': rows[1][3] == '1'}
    stops = [code for code, _ in STOPS if flags[code]]
    words = dict(STOPS)
    return {'ready': not stops, 'stops': stops, 'message': words[stops[0]] if stops else None}


class ZebraLink:
    """One printer, by its host and port."""

    def __init__(self, host: str, port: int = PORT, *, wait: float = 8.0):
        self.host, self.port, self.wait = host, int(port or PORT), wait

    def _connect(self, wait):
        try:
            return socket.create_connection((self.host, self.port), timeout=wait)
        except OSError as e:
            raise PrinterUnreachable(str(e)) from None

    def exchange(self, payload, *, wait=None, until_tag=False) -> str:
        """*payload* sent; what came back within *wait* seconds."""
        wait = self.wait if wait is None else wait
        conn = self._connect(wait)
        chunks = []
        with conn:
            try:
                conn.sendall(payload if isinstance(payload, bytes) else payload.encode('utf-8'))
            except OSError as e:
                raise PrinterUnreachable(str(e)) from None
            conn.settimeout(wait)
            try:
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    chunks.append(data)
                    text = b''.join(chunks).decode('latin-1').upper()
                    if until_tag and 'EPC=' in text and (HEX24.search(text.split('EPC=', 1)[-1])
                                                         or text.rstrip().endswith('EPC=')):
                        break
                    if not until_tag and text.count('\x03') >= 3:
                        break
            except socket.timeout:
                pass
            except OSError as e:
                if until_tag:
                    raise LinkLost(str(e)) from None
        return b''.join(chunks).decode('latin-1')

    def status(self) -> dict:
        return parse_status(self.exchange(STATUS, wait=4.0))

    def send(self, zpl: str) -> str:
        return self.exchange(zpl, until_tag=True)
