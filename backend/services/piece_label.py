"""A piece's label: one design, in ZPL, for the Zebra ZD621R (ADR-085 amendment of 20 Nov 2026).

The tag (EA9314, 66 x 26 mm): its head two faces of 25 x 13 mm side by side
along the feed, the fold between them -- the first blank, the second its
antenna with the chip in its middle; the tail off the second, across the web.
Measured on the owner's prints of 20 Nov: the label's top 18 dots below the
printer's, its head from the web's edge.

What is printed (the owner, 20 Nov; its code and its second face, 27 Nov; the design he approved
from its trial print, 27 Nov 2026: «اعتمد هذا التصميم»):
- first face, what a sale needs in one turn of the tag: the number's code; beside it the weight,
  «12.40» and a «g» half its height -- the largest line on the label [WEIGHT_H], shrunk to its
  column for a heavy piece, never cut; under it the karat reversed, white in a black box -- told at
  a glance, 18 from 21 -- the stones' weight beside it, «St 0.35g», only when the piece has stones;
  stones out of its weight -- its gold apart from its stones, priced by the carat -- marked
  «+St 0.35g» (the owner, 20 Nov 2026): the weight printed is what is sold as gold either way;
  and the number small under them; each set on its baseline in Cairo, measured;
- its code of one kind, Settings.piece_label_code (the owner, 27 Nov 2026: «اعداد
  لتحديد اي رمز يطبع QR, DM, BC وغيرها») -- POLICY: DataMatrix the default (the
  owner, 20 Nov, after reading bent labels at an angle: it reads better than QR),
  QR, Aztec -- each a square beside the words -- or Code 128 -- a bar across the
  face, the words under it. Whatever its kind it holds the number, so a reader
  types the same; the kinds the face holds, no other (Code 39 is wider than the
  face, EAN and UPC hold no letters);
- second face, upright as the first (the owner, 27 Nov 2026: «يبدأ النص من جهة
  الذيل» -- turned 180 degrees until then, it started away from the tail): the shop's
  name small at its top -- the settings' company name, given at each print, no word
  fixed here (the owner, 27 Nov 2026: «ليس بقيم ثابتة بل ديناميكيه مثل اسم المحل»),
  none set none printed -- then the model's name, else the category's -- Arabic, in
  Cairo -- above the chip's bump,
  and the size, «Sz 18», at the face's foot under it, only when the piece has
  one (the owner, 27 Nov 2026: a bump a millimetre wide in line with the tail's
  upper edge, where the dot of «ذهب» fell -- nothing prints on it; [BUMP_Y];
  the name 3 mm lower and the size 1 mm above the bottom edge, on his prints);
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
SIZE_H = 24                  # dots: the size's line
# The second face's lines where the owner put them on his prints (27 Nov 2026): the name 3 mm lower
# than it first printed -- from the fold's margin, 18 + 36 dots -- and the size at the face's foot,
# 1 mm above its bottom edge (2 mm, then «انزله ملي واحد فقط»).
NAME_Y = MARGIN + 36         # dots below the fold: the name's top
SIZE_FOOT = 12               # dots: the size's line ends this far above the face's bottom edge (1 mm)
# The shop's name in the room above the name (the owner's approved trial, 27 Nov 2026).
BRAND_Y, BRAND_H, BRAND_LEAST = MARGIN + 2, 22, 16

# The first face's words beside a square code (the owner's approved trial, 27 Nov 2026), in dots: the
# weight the largest line of the label, shrunk to its column, never cut; the karat reversed in a black
# box, the stones beside it on its row; the number under them, small; a gap between each.
WEIGHT_H, WEIGHT_LEAST = 58, 24
KARAT_H, KARAT_BOX, KARAT_PAD = 26, 32, 7
ROW_H, ROW_LEAST, ROW_GAP = 22, 14, 8
NUMBER_H, NUMBER_LEAST = 22, 14
LINE_GAP = 12
SQUARE_WORDS = {'weight': WEIGHT_H, 'karat': KARAT_H, 'box': KARAT_BOX, 'row': ROW_H, 'number': NUMBER_H,
                'gap': LINE_GAP}

# The code's kinds (Settings.piece_label_code; POLICY, the owner's choice): its square's side in dots.
# QR version 1 is 21 x 21 modules, 4 dots each -- 7 mm as the DataMatrix; Aztec compact of two layers
# 19 x 19, 4 dots each. Code 128 its own layout: a bar across the face.
CODE_KINDS = ('datamatrix', 'qr', 'aztec', 'code128')
DEFAULT_CODE = 'datamatrix'
QR_MODULE, AZTEC_MODULE = 4, 4
# The printer draws a QR lower than its field's origin (the owner's prints, 27 Nov 2026: «QR ليس في
# منتصف البطاقة عموديا بل الى الاسفل»; placed 10 dots higher it still had 5 mm above it and 1 mm under
# it -- drawn 34 dots under its origin): it is placed this much higher to sit in the middle.
QR_DROP = 34
SQUARE_SIDE = {'datamatrix': CODE_SIDE, 'qr': 21 * QR_MODULE, 'aztec': 19 * AZTEC_MODULE}
BAR_MODULE, BAR_H, BAR_QUIET = 2, 40, 20   # dots: a bar's narrowest, its height, its quiet zone each side
# The bar where the owner set it (27 Nov 2026: 2 mm lower, then «يمكن رفعه»), and under it the same
# words as beside a square code, smaller -- the room under the bar is 72 dots.
BAR_DROP = 4
BAR_WORDS = {'weight': 30, 'karat': 20, 'box': 24, 'row': 20, 'number': 18, 'gap': 6}

# The chip's bump on the second face (the owner, 27 Nov 2026): a millimetre wide, in line with the
# tail's upper edge -- where the dot of «ذهب» fell when the name stood at the face's edge, its line
# from 102 dots below the fold: its dots under the letters, turned over, nearest the fold. Nothing is
# drawn within its band; a framed test label draws the band -- on the bump itself, the owner checked
# on his print (27 Nov 2026: «الشريط على البقعه»).
BUMP_Y, BUMP_R, BUMP_CLEAR = 106, 6, 10    # dots below the fold: its middle, its half width, kept clear
BUMP_TOP = BUMP_Y - BUMP_R - BUMP_CLEAR    # the name ends above it; the size is under the bump
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


@lru_cache(maxsize=1)
def _cap_ratio() -> float:
    from fontTools.ttLib import TTFont
    font = TTFont(FONT_FILE)
    return font['glyf'][font.getBestCmap()[ord('4')]].yMax / font['head'].unitsPerEm


def cap(height: int) -> int:
    """How high a digit or a capital stands above its baseline at *height*, in dots -- from Cairo's «4»."""
    return round(_cap_ratio() * height)


def _whole(text: str, *, height: int, least: int, room: float) -> int:
    """The height *text* is set at, shrunk to *room* -- never cut: a weight or a number cut is a wrong one."""
    for h in range(height, least - 1, -1):
        if width(text, h) <= room:
            return h
    raise ValueError(f'«{text}» لا يتّسع لوجه البطاقة')


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


def code_kind(kind) -> str:
    """*kind* as one of [CODE_KINDS] -- nothing set is the default; anything else refused."""
    kind = str(kind or DEFAULT_CODE).strip().lower()
    if kind not in CODE_KINDS:
        raise ValueError(f'نوع رمز البطاقة {kind!r}: واحد من {", ".join(CODE_KINDS)}')
    return kind


def bar_width(number: str) -> int:
    """Code 128's width in dots, its quiet zones with it: «KJ-» in its set B, the digits in pairs in its
    set C -- an odd one first in B -- its check and stop; as the printer's automatic mode draws it."""
    digits = len(str(number)) - 3
    symbols = 1 + 3 + digits % 2 + 1 + digits // 2 + 1        # start, «KJ-», odd digit, to C, pairs, check
    return (symbols * 11 + 13) * BAR_MODULE + 2 * BAR_QUIET


def label_faces(number: str, *, karat=None, weight=None, name=None, stones=None, size=None,
                stones_out=False, code_type=None, brand=None) -> dict:
    """What each face says, as it reads -- the one source of the printed label
    and of its preview (ADR-097 ط5): the code's kind and value and the number;
    the weight, the karat and the stones -- «+St» when out of the weight -- on
    the first face; the shop's name and the piece's, as fitted (cut with «…»
    when too long), and the size on the second."""
    stone_mark = '+St' if stones_out else 'St'
    stones_said = f'{stone_mark} {_grams(stones)}' if stones and float(stones) > 0 else None
    size_said = f'Sz {size}' if size not in (None, '') else None
    shown = fitted_text(name, height=NAME_H, least=NAME_MIN)[0] if name else ''
    brand = str(brand or '').strip()
    brand_shown = fitted_text(brand, height=BRAND_H, least=BRAND_LEAST)[0] if brand else ''
    return {'code': str(number), 'code_type': code_kind(code_type), 'number': str(number),
            'weight': _grams(weight) if weight else None, 'karat': f'{karat}K' if karat else None,
            'stones': stones_said, 'name': shown or None, 'size': size_said, 'brand': brand_shown or None}


def label_zpl(number: str, *, karat=None, weight=None, name=None, stones=None, size=None, stones_out=False,
              frame=False, epc=None, write_tag=True, code_type=None, brand=None) -> str:
    """One label in ZPL: the tag written and read back to the host, then its two
    faces. *epc*: the attempt's value (ADR-097) -- generation 0 when not given.
    *write_tag* False: a test label, its faces only -- no tag written, none read.
    *code_type*: the code's kind ([CODE_KINDS]) -- DataMatrix when not given.
    *brand*: the shop's name, the settings' -- none given, none printed.
    *frame*: the faces as measured and the chip's bump, to be checked on the tag."""
    kind = code_kind(code_type)
    if len(str(number)) - 3 > CODE_DIGITS:
        raise ValueError(f'رقم القطعة {number} أطول من رمز البطاقة ({CODE_DIGITS} أرقام)')
    if kind == 'code128' and bar_width(number) > FACE_W:
        raise ValueError(f'رقم القطعة {number} أطول من أن يتّسع له Code 128 على وجه البطاقة: '
                         'اختر رمزًا مربعًا (DataMatrix أو QR أو Aztec)')
    if write_tag:
        epc = epc or epc_of(number)
        if epc[4:].isdigit() is False or int(epc[8:]) != int(str(number)[3:]):
            raise ValueError(f'رمز الرقاقة {epc} ليس للقطعة {number}')
    first, second = TOP, TOP + FACE_H
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
                        stones_out=stones_out, code_type=kind, brand=brand)
    lines += _first_face(number, kind, faces, first)
    lines += _second_face(faces['brand'], name, faces['size'], second)
    if frame:                                                   # the faces as measured, to be checked on the tag
        lines += [f'^FO0,{first}^GB{FACE_W},{FACE_H},2^FS', f'^FO0,{second}^GB{FACE_W},{FACE_H},2^FS',
                  f'^FO0,{second + BUMP_Y - BUMP_R}^GB{FACE_W},{2 * BUMP_R},1^FS']
    lines.append('^XZ')
    return '\n'.join(lines) + '\n'


def _set(x, baseline, h, text, reverse=False) -> str:
    """A line set on its baseline in Cairo -- its place measured here, not left to a field block."""
    return f'^FT{round(x)},{round(baseline)}^A@N,{h},{h},{FONT_ON_PRINTER}{"^FR" if reverse else ""}^FD{text}^FS'


def _words(faces: dict, left: int, right: int, top: int, bottom: int, size: dict) -> list:
    """The weight, the karat's row and the number, each only when there is one, stacked in the middle
    of top..bottom within left..right -- sizes from *size* (SQUARE_WORDS beside a square, BAR_WORDS
    under a bar)."""
    room = right - left
    blocks = []                                          # (height, draw(y_top) -> lines)
    if faces['weight']:
        digits, unit = faces['weight'][:-1], faces['weight'][-1]
        wh = size['weight']
        while wh > WEIGHT_LEAST and width(digits, wh) + 2 + width(unit, wh // 2) > room:
            wh -= 1
        if width(digits, wh) + 2 + width(unit, wh // 2) > room:
            raise ValueError(f'الوزن {faces["weight"]} لا يتّسع لوجه البطاقة')

        def weight(y, wh=wh, digits=digits, unit=unit):
            x = left + (room - width(digits, wh) - 2 - width(unit, wh // 2)) / 2
            return [_set(x, y + cap(wh), wh, digits), _set(x + width(digits, wh) + 2, y + cap(wh), wh // 2, unit)]
        blocks.append((cap(wh), weight))
    if faces['karat'] or faces['stones']:
        kh, box = size['karat'], size['box']
        bw = round(width(faces['karat'], kh)) + 2 * KARAT_PAD if faces['karat'] else 0
        gap = ROW_GAP if faces['karat'] and faces['stones'] else 0
        sh = _whole(faces['stones'], height=size['row'], least=ROW_LEAST, room=room - bw - gap) \
            if faces['stones'] else 0
        row_w = bw + gap + (width(faces['stones'], sh) if faces['stones'] else 0)

        def row(y, kh=kh, box=box, bw=bw, gap=gap, sh=sh, row_w=row_w):
            x, out = left + (room - row_w) / 2, []
            if faces['karat']:
                out += [f'^FO{round(x)},{y}^GB{bw},{box},{box}^FS',
                        _set(x + KARAT_PAD, y + (box + cap(kh)) // 2, kh, faces['karat'], reverse=True)]
            if faces['stones']:
                out.append(_set(x + bw + gap, y + (box + cap(sh)) // 2, sh, faces['stones']))
            return out
        blocks.append((box, row))
    nh = _whole(faces['number'], height=size['number'], least=NUMBER_LEAST, room=room)
    blocks.append((cap(nh), lambda y: [_set(left + (room - width(faces['number'], nh)) / 2, y + cap(nh), nh,
                                            faces['number'])]))
    total = sum(h for h, _ in blocks) + size['gap'] * (len(blocks) - 1)
    if total > bottom - top:
        raise ValueError('كلام الوجه الأول لا يتّسع له')
    y, out = top + (bottom - top - total) // 2, []
    for h, draw in blocks:
        out += draw(y)
        y += h + size['gap']
    return out


def _first_face(number: str, kind: str, faces: dict, first: int) -> list:
    """The code, and the weight, the karat's row and the number beside it -- under it for Code 128."""
    if kind == 'code128':                                       # a bar across the face, the words under it
        bars = bar_width(number) - 2 * BAR_QUIET
        top = first + MARGIN + BAR_DROP
        out = [f'^BY{BAR_MODULE},3,{BAR_H}',
               f'^FO{(FACE_W - bars) // 2},{top}^BCN,{BAR_H},N,N,N,A^FD{number}^FS']
        return out + _words(faces, MARGIN, FACE_W - MARGIN, top + BAR_H + 4, first + FACE_H - MARGIN, BAR_WORDS)
    side = SQUARE_SIDE[kind]
    y_code = first + (FACE_H - side) // 2 - (QR_DROP if kind == 'qr' else 0)
    code = {'datamatrix': f'^BXN,{CODE_CELL},200,14,14^FD{number}^FS',
            'qr': f'^BQN,2,{QR_MODULE}^FDMA,{number}^FS',
            'aztec': f'^BON,{AZTEC_MODULE},N,102,N,1^FD{number}^FS'}[kind]
    out = [f'^FO{MARGIN},{y_code}{code}']
    left = MARGIN + side + MARGIN
    return out + _words(faces, left, FACE_W - MARGIN, first + MARGIN, first + FACE_H - MARGIN, SQUARE_WORDS)


def _second_face(brand, name, size_said, second: int) -> list:
    """Upright, as the first (the owner, 27 Nov 2026: «يبدأ النص من جهة الذيل»): the tail leaves this
    face on its right, where Arabic starts -- both faces read with the tail on the right, the folded
    tag turned over top to bottom. The shop's name small at its top ([BRAND_Y]); the piece's name
    where the owner put it, ending above the chip's bump ([BUMP_TOP]); the size at the face's foot,
    under the bump ([SIZE_FOOT])."""
    drawn, h = fitted(name, height=NAME_H, least=NAME_MIN) if name else ('', 0)
    out = []
    if brand:
        shop, bh = fitted(brand, height=BRAND_H, least=BRAND_LEAST)
        out.append(f'^FO{MARGIN},{second + BRAND_Y}^A@N,{bh},{bh},{FONT_ON_PRINTER}^FB{ROOM},1,0,C^FD{shop}^FS')
    if drawn:
        out.append(f'^FO{MARGIN},{second + NAME_Y}^A@N,{h},{h},{FONT_ON_PRINTER}^FB{ROOM},1,0,C^FD{drawn}^FS')
    if size_said:
        y = second + FACE_H - SIZE_FOOT - SIZE_H
        out.append(f'^FO{MARGIN},{y}^A@N,{SIZE_H},{SIZE_H},{FONT_ON_PRINTER}^FB{ROOM},1,0,C^FD{size_said}^FS')
    return out


def font_upload() -> bytes:
    """The command that keeps Cairo in the printer's flash (E:CAIRO.TTF) -- once per printer."""
    data = open(FONT_FILE, 'rb').read()
    drive, stem = FONT_ON_PRINTER.split(':')
    return f'~DY{drive}:{stem.rsplit(".", 1)[0]},B,T,{len(data)},0,'.encode() + data
