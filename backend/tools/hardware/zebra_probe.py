"""The printer's first test (ADR-085 ت0; ADR-087 R5): one tag written, its label printed, and the printer asked back.

The Zebra ZD621R on the shop's network (ADR-085: ZPL on port 9100, the tag
written with ^RFW). This tool talks to it alone: it writes no row, reads no
database, imports nothing of the system -- it runs on any computer on the
shop's network with Python 3, the server's or another.

    python tools/hardware/zebra_probe.py --host 192.168.1.50 --dry-run
    python tools/hardware/zebra_probe.py --host 192.168.1.50 --status
    python tools/hardware/zebra_probe.py --host 192.168.1.50 --calibrate
    python tools/hardware/zebra_probe.py --host 192.168.1.50 --number KJ-000001 \\
        --karat 21 --weight 12.40 --width-mm 72 --height-mm 12

A label: the piece's number, its karat and weight when given, and a
DataMatrix of the number (the counter scans it, ADR-085). Its tag: the
number's value (4B4A then the digits padded to twenty, ADR-085 law 2), read
back by the printer (^RFR, ^HV) -- a tag is never taken as written on the
printer's word alone: the value it reads must be the value sent.

Not a writer: the station's printing (R5) is built after this test passes.
"""
from __future__ import annotations

import argparse
import re
import socket
import sys

EPC_PREFIX = '4B4A'          # «KJ» -- as services.pieces.EPC_PREFIX (a test holds them one)
PORT = 9100
DOTS_PER_MM = 12             # 300 dpi
NUMBER = re.compile(r'^KJ-\d{6,}$')
HEX24 = re.compile(r'[0-9A-F]{24}')


def epc_of(number: str) -> str:
    """The number's tag value (ADR-085 law 2) -- services.pieces.epc_of's, held one by a test."""
    if not NUMBER.match(str(number or '')):
        raise ValueError(f'رقم القطعة KJ- ثم ستة أرقام فأكثر: {number!r}')
    return f'{EPC_PREFIX}{int(str(number)[3:]):020d}'


def label_zpl(number: str, *, karat=None, weight=None, width_mm=72.0, height_mm=12.0) -> str:
    """One label in ZPL: the tag written and read back to the host, then the
    number, its karat and weight, and its DataMatrix."""
    epc = epc_of(number)
    width, height = round(width_mm * DOTS_PER_MM), round(height_mm * DOTS_PER_MM)
    module = max(2, min(6, height // 30))                      # the DataMatrix's cell, in dots
    text_h = max(18, min(40, height // 3))
    facts = ' · '.join(x for x in (f'{karat}K' if karat else '', f'{float(weight):.2f}g' if weight else '') if x)
    lines = [
        '^XA',
        f'^PW{width}', f'^LL{height}', '^CI28',
        '^RS8',                                                 # EPC Class 1 Gen 2
        f'^RFW,H,,,A^FD{epc}^FS',                               # the tag written, its PC bits set
        '^FN1^RFR,H^FS', '^HV1,24,EPC=^FS',                    # read back, returned to the host
        f'^FO10,{max(4, (height - module * 14) // 2)}^BXN,{module},200^FD{number}^FS',
        f'^FO{10 + module * 16},6^A0N,{text_h},{text_h}^FD{number}^FS',
    ]
    if facts:
        lines.append(f'^FO{10 + module * 16},{6 + text_h + 4}^A0N,{text_h},{text_h}^FD{facts}^FS')
    lines.append('^XZ')
    return '\n'.join(lines) + '\n'


CALIBRATE = '~JC\n^XA^HR^XZ\n'      # the media sensed, then the tag's position (prints its own report)
STATUS = '~HS\n'


def read_back(reply: str):
    """The value the printer read back from the tag (^HV), or None."""
    match = HEX24.search(str(reply or '').upper().split('EPC=', 1)[-1])
    return match.group(0) if match else None


def send(host: str, payload: str, *, wait: float = 8.0) -> str:
    """The payload sent to the printer, and what it answers within `wait` seconds."""
    with socket.create_connection((host, PORT), timeout=wait) as conn:
        conn.sendall(payload.encode('utf-8'))
        conn.settimeout(wait)
        chunks = []
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                chunks.append(data)
                if b'EPC=' in b''.join(chunks) and HEX24.search(b''.join(chunks).decode('latin-1').upper()):
                    break
        except socket.timeout:
            pass
    return b''.join(chunks).decode('latin-1')


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--host', required=True, help='عنوان الطابعة على شبكة المحل')
    p.add_argument('--number', default='KJ-000001')
    p.add_argument('--karat')
    p.add_argument('--weight', type=float)
    p.add_argument('--width-mm', type=float, default=72.0)
    p.add_argument('--height-mm', type=float, default=12.0)
    what = p.add_mutually_exclusive_group()
    what.add_argument('--dry-run', action='store_true', help='اطبع الأوامر هنا ولا ترسلها')
    what.add_argument('--status', action='store_true', help='اسأل الطابعة عن حالتها')
    what.add_argument('--calibrate', action='store_true', help='معايرة الورق ثم موضع الرقاقة')
    a = p.parse_args(argv)

    if a.status:
        print(send(a.host, STATUS, wait=4.0) or '(لا ردّ)')
        return 0
    if a.calibrate:
        send(a.host, CALIBRATE, wait=2.0)
        print('أُرسلت المعايرة: الطابعة تُخرج بضع بطاقات ثم ورقة تقرير موضع الرقاقة.')
        return 0
    zpl = label_zpl(a.number, karat=a.karat, weight=a.weight, width_mm=a.width_mm, height_mm=a.height_mm)
    if a.dry_run:
        print(zpl)
        return 0
    expected = epc_of(a.number)
    reply = send(a.host, zpl)
    got = read_back(reply)
    print(f'أُرسل:   {expected}')
    print(f'قُرئ:    {got or "(لا شيء)"}')
    if got == expected:
        print('✓ كُتبت الرقاقة وقُرئت كما أُرسلت.')
        return 0
    print('✗ لم تؤكد الطابعة الرقاقة. الرد كما جاء:', repr(reply[:300]))
    return 1


if __name__ == '__main__':
    sys.exit(main())
