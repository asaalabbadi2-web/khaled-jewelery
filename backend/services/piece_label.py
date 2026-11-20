"""A piece's label: one design, in ZPL, for the Zebra ZD621R (ADR-085 amendment of 20 Nov 2026).

The tag (EA9314, 66 x 26 mm): its head two faces of 25 x 13 mm side by side
along the feed, the fold between them -- the first blank, the second its
antenna with the chip in its middle; the tail off the second, across the web.
Measured on the owner's prints of 20 Nov: the label's top 18 dots below the
printer's, its head from the web's edge.

What is printed (the owner, 20 Nov):
- first face: the number's DataMatrix (the owner, 20 Nov, after reading
  bent labels at an angle: it reads better than QR; a phone reads it through
  the system, not its camera), the number, the karat and weight -- «21K · 12.40g»;
- second face, turned 180 degrees so it reads upright when the folded tag is
  turned over, the chip in its middle left clear: at its edge the model's
  name, else the category's -- Arabic, in Cairo; by the fold the stones'
  weight and the size in Latin symbols -- «St 0.35g · Sz 18» -- each only
  when the piece has it; stones out of its weight -- its gold apart from its
  stones, priced by the carat -- marked «+St 0.35g» (the owner, 20 Nov 2026):
  the weight printed is what is sold as gold either way;
- no price (live, §13), no wage, no cost;
- printed slowly and dark: 2 inches a second, darkness 20 -- the owner chose
  the sharpest of three prints.

Arabic: the printer's own fonts hold no Arabic joining -- the first print came
out reversed and broken. The text is joined and laid right-to-left here, in
Cairo's presentation forms (Cairo lacks the isolated forms: a letter standing
alone is its own letter), its marks dropped, and sent with the printer's own
shaping off (^PA0,0,0,0). Its width is measured from Cairo's advances: a line
too wide shrinks, then is cut with «…» -- two printed lines never overlap.

Pure: no database, no request. services/pieces gives it a piece's facts; the
probe (tools/hardware/zebra_probe.py) prints it.
"""
from __future__ import annotations

import os
import re
import unicodedata
from functools import lru_cache

DOTS_PER_MM = 12             # 300 dpi
EPC_PREFIX = '4B4A'          # «KJ» -- as services.pieces.EPC_PREFIX (a test holds them one)
NUMBER = re.compile(r'^KJ-\d{6,}$')

TOP = 18                     # dots: the label's top below the printer's
FACE_W, FACE_H = 300, 156    # dots: 25 x 13 mm
MARGIN = 18                  # dots: 1.5 mm kept clear inside each face's edge
ROOM = FACE_W - 2 * MARGIN   # a line's width on a face
CODE_CELL = 6                # dots: 0.5 mm a cell of the DataMatrix
CODE_SIDE = CODE_CELL * 14   # 14 x 14 cells -- 7 mm: «KJ-» and up to 10 digits (8 codewords)
CODE_DIGITS = 10
NAME_H, NAME_MIN = 36, 24    # dots: the name's height, and the least it shrinks to
FACTS_H = 28
SPEED, DARKNESS = 2, 20      # 2 inches a second, darkness 20 of 30: the sharpest of three on the owner's
                             # resin ribbon and PET tags (20 Nov; 6 and 10, the printer's own, the least)

FONT_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         'assets', 'fonts', 'Cairo-Bold.ttf')
FONT_ON_PRINTER = 'E:CAIRO.TTF'
ELLIPSIS = '…'


def epc_of(number: str, generation: int = 0) -> str:
    """The number's tag value (ADR-097 law 2): 4B4A, the generation in four
    digits, the number in sixteen -- services.pieces.epc_of's, held one by a test."""
    if not NUMBER.match(str(number or '')):
        raise ValueError(f'رقم القطعة KJ- ثم ستة أرقام فأكثر: {number!r}')
    n, generation = int(str(number)[3:]), int(generation)
    if not 1 <= n < 10 ** 16 or not 0 <= generation <= 9999:
        raise ValueError(f'رقم القطعة أو جيل الرقاقة خارج حدّه: {number!r} {generation}')
    return f'{EPC_PREFIX}{generation:04d}{n:016d}'


@lru_cache(maxsize=1)
def _font():
    from fontTools.ttLib import TTFont
    font = TTFont(FONT_FILE)
    return font.getBestCmap(), font['hmtx'], font['head'].unitsPerEm


def _in_font(ch: str) -> str:
    cmap = _font()[0]
    if ord(ch) in cmap:
        return ch
    parts = unicodedata.decomposition(ch).split()
    if parts and parts[0] == '<isolated>':                 # a letter alone is its own letter in Cairo
        return ''.join(chr(int(p, 16)) for p in parts[1:])
    return ch


def shaped(text: str) -> str:
    """*text* as the printer is to draw it: its letters joined, laid right to left, its marks dropped."""
    from arabic_reshaper import reshape
    from bidi.algorithm import get_display
    bare = ''.join(c for c in str(text) if unicodedata.category(c) != 'Mn')
    return ''.join(_in_font(c) for c in get_display(reshape(bare)))


def width(drawn: str, height: int) -> float:
    """A drawn line's width in dots at *height*, from Cairo's advances."""
    cmap, hmtx, upm = _font()
    return sum(hmtx[cmap[ord(c)]][0] for c in drawn if ord(c) in cmap) * height / upm


def fitted_text(text: str, *, height: int, least: int, room: int = ROOM):
    """(shown, drawn, height): *text* at *height*, shrunk down to *least*, then
    cut with «…» -- within *room*. *shown* as it reads (the preview's), *drawn*
    as the printer draws it."""
    drawn = shaped(text)
    for h in range(height, least - 1, -1):
        if width(drawn, h) <= room:
            return str(text), drawn, h
    words = str(text)
    while words:
        words = words[:-1].rstrip()
        drawn = shaped(words + ELLIPSIS)
        if width(drawn, least) <= room:
            return words + ELLIPSIS, drawn, least
    return '', '', least


def fitted(text: str, *, height: int, least: int, room: int = ROOM):
    """(drawn, height) -- fitted_text's, for the printer."""
    _, drawn, h = fitted_text(text, height=height, least=least, room=room)
    return drawn, h


def _grams(value) -> str:
    return f'{float(value):.2f}g'


def label_faces(number: str, *, karat=None, weight=None, name=None, stones=None, size=None,
                stones_out=False) -> dict:
    """What each face says, as it reads -- the one source of the printed label
    and of its preview (ADR-097 ط5): the code's value and the number; the
    karat and weight; the name as fitted (cut with «…» when too long); the
    stones -- «+St» when out of the weight -- and size."""
    facts = ' · '.join(x for x in (f'{karat}K' if karat else '', _grams(weight) if weight else '') if x)
    stone_mark = '+St' if stones_out else 'St'
    marks = ' · '.join(x for x in (f'{stone_mark} {_grams(stones)}' if stones and float(stones) > 0 else '',
                                   f'Sz {size}' if size not in (None, '') else '') if x)
    shown = fitted_text(name, height=NAME_H, least=NAME_MIN)[0] if name else ''
    return {'code': str(number), 'number': str(number), 'facts': facts or None, 'name': shown or None,
            'marks': marks or None}


def label_zpl(number: str, *, karat=None, weight=None, name=None, stones=None, size=None, stones_out=False,
              frame=False, epc=None, write_tag=True) -> str:
    """One label in ZPL: the tag written and read back to the host, then its two
    faces. *epc*: the attempt's value (ADR-097) -- generation 0 when not given.
    *write_tag* False: a test label, its faces only -- no tag written, none read."""
    if len(str(number)) - 3 > CODE_DIGITS:
        raise ValueError(f'رقم القطعة {number} أطول من رمز البطاقة ({CODE_DIGITS} أرقام)')
    if write_tag:
        epc = epc or epc_of(number)
        if epc[4:].isdigit() is False or int(epc[8:]) != int(str(number)[3:]):
            raise ValueError(f'رمز الرقاقة {epc} ليس للقطعة {number}')
    first, second = TOP, TOP + FACE_H
    text_x = MARGIN + CODE_SIDE + MARGIN
    column = FACE_W - MARGIN - text_x
    lines = [
        f'~SD{DARKNESS}',                                       # absolute, whatever the printer was left at
        '^XA', f'^PR{SPEED},{SPEED},{SPEED}', f'^PW{round(66 * DOTS_PER_MM)}', f'^LL{round(26 * DOTS_PER_MM)}', '^CI28',
        '^PA0,0,0,0',                                           # shaped here, not by the printer
    ]
    if write_tag:
        lines += ['^RS8',                                       # EPC Class 1 Gen 2
                  f'^RFW,H,,,A^FD{epc}^FS',                     # the tag written, its PC bits set
                  '^FN1^RFR,H^FS', '^HV1,24,EPC=^FS']          # read back, returned to the host
    faces = label_faces(number, karat=karat, weight=weight, name=name, stones=stones, size=size,
                        stones_out=stones_out)
    facts, marks = faces['facts'], faces['marks']
    lines.append(f'^FO{MARGIN},{first + (FACE_H - CODE_SIDE) // 2}^BXN,{CODE_CELL},200,14,14^FD{number}^FS')
    if facts:
        lines += [f'^FO{text_x},{first + FACE_H // 2 - 36}^A0N,32,32^FB{column},1,0,C^FD{number}^FS',
                  f'^FO{text_x},{first + FACE_H // 2 + 4}^A0N,28,28^FB{column},1,0,C^FD{facts}^FS']
    else:
        lines.append(f'^FO{text_x},{first + (FACE_H - 32) // 2}^A0N,32,32^FB{column},1,0,C^FD{number}^FS')
    if name:                                                    # the second face's edge, the chip its middle
        drawn, h = fitted(name, height=NAME_H, least=NAME_MIN)
        if drawn:
            lines.append(f'^FO{MARGIN},{second + FACE_H - MARGIN - h}^A@I,{h},{h},{FONT_ON_PRINTER}'
                         f'^FB{ROOM},1,0,C^FD{drawn}^FS')
    if marks:                                                   # by the fold
        drawn, h = fitted(marks, height=FACTS_H, least=NAME_MIN)
        lines.append(f'^FO{MARGIN},{second + MARGIN}^A@I,{h},{h},{FONT_ON_PRINTER}^FB{ROOM},1,0,C^FD{drawn}^FS')
    if frame:                                                   # the faces as measured, to be checked on the tag
        lines += [f'^FO0,{first}^GB{FACE_W},{FACE_H},2^FS', f'^FO0,{second}^GB{FACE_W},{FACE_H},2^FS']
    lines.append('^XZ')
    return '\n'.join(lines) + '\n'


def font_upload() -> bytes:
    """The command that keeps Cairo in the printer's flash (E:CAIRO.TTF) -- once per printer."""
    data = open(FONT_FILE, 'rb').read()
    drive, stem = FONT_ON_PRINTER.split(':')
    return f'~DY{drive}:{stem.rsplit(".", 1)[0]},B,T,{len(data)},0,'.encode() + data
