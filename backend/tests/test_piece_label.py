"""A piece's label (ADR-085 amendment, the owner, 20 Nov 2026): one design, on the tag's two faces.

The owner's prints of 20 Nov: the first cut the number at the top and laid
the code across the fold -- the scanner read nothing; the printer's own fonts
drew Arabic reversed and broken; two long lines overprinted each other. Here:
- the QR code whole inside the first face, the number, karat and weight beside it;
- the second face turned over, the chip in its middle clear: the name in
  Arabic at its edge, the stones and size in Latin symbols by the fold;
- Arabic joined and laid right to left here, the printer's shaping off;
- no line wider than its face: it shrinks, then is cut with «…»;
- no price, no wage.

Run:
    python -m pytest tests/test_piece_label.py -v
"""
import re

import pytest

from services import piece_label as L
from services.pieces import EPC_PREFIX, epc_of as system_epc


def _zpl(**facts):
    return L.label_zpl('KJ-000124', karat='21', weight=12.4, **facts)


def _field(zpl, command):
    """(x, y, h) of the field drawn with *command* (^BQN / ^A0N / ^A@I)."""
    x, y, h = re.search(rf'\^FO(\d+),(\d+)\{command}[,]?(?:2,)?(\d+)', zpl).groups()
    return int(x), int(y), int(h)


@pytest.mark.parametrize('number', ['KJ-000001', 'KJ-000124', 'KJ-1234567'])
def test_its_tag_value_is_the_systems(number):
    assert L.EPC_PREFIX == EPC_PREFIX and L.epc_of(number) == system_epc(number)


def test_the_tag_is_written_and_read_back():
    zpl = _zpl()
    assert zpl.startswith('~SD20\n^XA') and zpl.rstrip().endswith('^XZ')
    assert '^RFW,H,,,A^FD4B4A00000000000000000124^FS' in zpl
    assert '^RFR,H' in zpl and '^HV1,24,EPC=' in zpl, 'read back to the host'


def test_the_first_face_its_code_number_karat_and_weight():
    zpl = _zpl()
    assert '^BQN,2,4^FDQA,KJ-000124^FS' in zpl, 'the QR code the scanner reads unset'
    x, y, _ = _field(zpl, '^BQN')
    top = y + L.QR_TOP
    assert L.TOP + L.MARGIN <= top and top + L.QR_SIDE <= L.TOP + L.FACE_H - L.MARGIN, 'not across the fold'
    assert L.MARGIN <= x and x + L.QR_SIDE <= L.FACE_W - L.MARGIN
    assert '^FDKJ-000124^FS' in zpl and '^FD21K · 12.40g^FS' in zpl


def test_the_second_face_turned_over_its_chip_clear():
    zpl = _zpl(name='بنجرة مخرمة', stones=0.35, size='18')
    second, chip = L.TOP + L.FACE_H, L.TOP + L.FACE_H + L.FACE_H // 2
    name = re.search(r'\^FO\d+,(\d+)\^A@I,(\d+),\d+,E:CAIRO\.TTF\^FB\d+,1,0,C\^FD([^\^]*)\^FS', zpl)
    y, h = int(name.group(1)), int(name.group(2))
    assert y - chip >= L.MARGIN and y + h <= second + L.FACE_H - L.MARGIN, 'the name at its edge, off the chip'
    marks = re.search(r'\^FO\d+,(\d+)\^A@I,(\d+),\d+,E:CAIRO\.TTF\^FB\d+,1,0,C\^FDSt 0\.35g · Sz 18\^FS', zpl)
    assert marks, 'the stones and size in Latin symbols'
    y, h = int(marks.group(1)), int(marks.group(2))
    assert y >= second + L.MARGIN and chip - (y + h) >= L.MARGIN, 'by the fold, off the chip'


def test_each_mark_only_when_the_piece_has_it():
    assert 'St ' not in _zpl(stones=0.0) and 'Sz ' not in _zpl(size='')
    assert '^FDSz 18^FS' in _zpl(size='18') and '^FDSt 1.20g^FS' in _zpl(stones=1.2)
    assert '^A@' not in _zpl(), 'no name, no marks: nothing on the second face but the facts'


def test_arabic_is_joined_and_laid_right_to_left_here():
    """The printer's shaping off; the letters in their joined forms, the last first."""
    zpl = _zpl(name='بنجرة')
    assert '^PA0,0,0,0' in zpl
    drawn = L.shaped('بنجرة')
    assert drawn[-1] == 'ﺑ', 'ب joined to what follows, drawn last: the line reads from the right'
    assert drawn[0] == 'ة', 'ة alone after ر: its own letter -- Cairo has no isolated form'
    assert L.shaped('بنجرة 21').startswith('21 '), 'its number stays as it is read'
    assert L.shaped('مخرّمة') == L.shaped('مخرمة'), 'its marks dropped'


def test_every_letter_drawn_is_in_the_font():
    from fontTools.ttLib import TTFont
    cmap = TTFont(L.FONT_FILE).getBestCmap()
    for name in ('بنجرة مخرمة', 'خاتم سوليتير لؤلؤ', 'طقم إيطالي', 'سلسلة لا تُصدأ', 'St 0.35g · Sz 18'):
        assert all(ord(c) in cmap for c in L.shaped(name)), name


def test_no_line_wider_than_its_face():
    for name in ('بنجرة', 'خاتم سوليتير لؤلؤ', 'طقم ذهب إيطالي مرصع بفصوص زركون ملونة كبير'):
        drawn, h = L.fitted(name, height=L.NAME_H, least=L.NAME_MIN)
        assert L.NAME_MIN <= h <= L.NAME_H and L.width(drawn, h) <= L.ROOM, name
    long_name = L.fitted('طقم ذهب إيطالي مرصع بفصوص زركون ملونة كبير', height=L.NAME_H, least=L.NAME_MIN)[0]
    assert '…' in long_name, 'cut with «…»'
    assert L.fitted('بنجرة', height=L.NAME_H, least=L.NAME_MIN)[1] == L.NAME_H, 'a short name not shrunk'


def test_no_price_no_wage():
    from inspect import signature
    assert not {'price', 'wage', 'cost'} & set(signature(L.label_zpl).parameters)


def test_printed_slowly_and_dark():
    """The owner's choice of three prints (20 Nov): 2 inches a second, darkness 20 -- set on every label,
    absolute, not left to what the printer was set to."""
    zpl = _zpl()
    assert '^PR2,2,2' in zpl and zpl.startswith('~SD20') and '^MD' not in zpl
