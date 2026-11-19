"""The printer's test (ADR-085 ت0; ADR-087 R5): one tag written, its label printed, and the printer asked back.

The Zebra ZD621R on the network (ADR-085: ZPL on port 9100, the tag written
with ^RFW). This tool talks to it alone: it writes no row and reads no
database. Its label is the system's one design (services/piece_label): the
number's QR code, the number, karat and weight on the first face; the model's
or category's name in Arabic (Cairo), the stones and size in Latin symbols on
the second -- run from backend/ with the server's libraries.

    python tools/hardware/zebra_probe.py --host 192.168.1.50 --dry-run
    python tools/hardware/zebra_probe.py --host 192.168.1.50 --status
    python tools/hardware/zebra_probe.py --host 192.168.1.50 --install-font
    python tools/hardware/zebra_probe.py --host 192.168.1.50 --calibrate
    python tools/hardware/zebra_probe.py --host 192.168.1.50 --number KJ-999905 \\
        --karat 21 --weight 12.40 --name 'بنجرة مخرمة' --stones 0.35 --size 18

A tag is never taken as written on the printer's word alone: the value it
reads back (^RFR, ^HV) must be the value sent. A new printer takes the font
once (--install-font): Cairo kept in its flash as E:CAIRO.TTF.
"""
from __future__ import annotations

import argparse
import os
import re
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from services.piece_label import (EPC_PREFIX, FONT_ON_PRINTER, epc_of, font_upload,  # noqa: E402,F401
                                  label_zpl)

PORT = 9100
HEX24 = re.compile(r'[0-9A-F]{24}')


CALIBRATE = '~JC\n^XA^HR^XZ\n'      # the media sensed, then the tag's position (prints its own report)
STATUS = '~HS\n'


def read_back(reply: str):
    """The value the printer read back from the tag (^HV), or None."""
    match = HEX24.search(str(reply or '').upper().split('EPC=', 1)[-1])
    return match.group(0) if match else None


def send(host: str, payload, *, wait: float = 8.0) -> str:
    """The payload (text or bytes) sent to the printer, and what it answers within `wait` seconds."""
    with socket.create_connection((host, PORT), timeout=max(wait, 30.0)) as conn:
        conn.sendall(payload if isinstance(payload, bytes) else payload.encode('utf-8'))
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
    p.add_argument('--name', help='اسم الموديل أو التصنيف (بالعربية)')
    p.add_argument('--stones', type=float, help='وزن الأحجار بالجرام')
    p.add_argument('--size', help='المقاس')
    p.add_argument('--frame', action='store_true', help='ارسم حدود الوجهين كما قيست، للتحقق على البطاقة')
    what = p.add_mutually_exclusive_group()
    what.add_argument('--dry-run', action='store_true', help='اطبع الأوامر هنا ولا ترسلها')
    what.add_argument('--status', action='store_true', help='اسأل الطابعة عن حالتها')
    what.add_argument('--calibrate', action='store_true', help='معايرة الورق ثم موضع الرقاقة')
    what.add_argument('--install-font', action='store_true', help='حمّل الخط Cairo إلى ذاكرة الطابعة (مرة لكل طابعة)')
    a = p.parse_args(argv)

    if a.status:
        print(send(a.host, STATUS, wait=4.0) or '(لا ردّ)')
        return 0
    if a.calibrate:
        send(a.host, CALIBRATE, wait=2.0)
        print('أُرسلت المعايرة: الطابعة تُخرج بضع بطاقات ثم ورقة تقرير موضع الرقاقة.')
        return 0
    if a.install_font:
        send(a.host, font_upload(), wait=3.0)
        listed = send(a.host, f'^XA^HW{FONT_ON_PRINTER.split(".")[0]}.*^XZ\n', wait=4.0)
        ok = FONT_ON_PRINTER in listed
        print(f'{"✓" if ok else "✗"} الخط {FONT_ON_PRINTER} {"في ذاكرة الطابعة" if ok else "لم يظهر في ذاكرة الطابعة"}')
        return 0 if ok else 1
    zpl = label_zpl(a.number, karat=a.karat, weight=a.weight, name=a.name, stones=a.stones, size=a.size,
                    frame=a.frame)
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
