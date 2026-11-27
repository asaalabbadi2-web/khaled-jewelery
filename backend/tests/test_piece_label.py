"""A piece's label (ADR-085 amendment, the owner, 20 Nov 2026): one design, on the tag's two faces.

The owner's prints of 20 Nov: the first cut the number at the top and laid
the code across the fold -- the scanner read nothing; the printer's own fonts
drew Arabic reversed and broken; two long lines overprinted each other. Here:
- the DataMatrix whole inside the first face (the owner, 20 Nov: it reads bent and at an angle
  better than QR), the number, karat and weight beside it;
- the second face upright, starting from the tail as Arabic starts (the owner, 27 Nov 2026): the name
  in Arabic and the size under it, in the middle of what is
  clear of the chip's bump; the stones on the first face, under the weight (the owner, 27 Nov 2026:
  a bump a millimetre wide in line with the tail's upper edge took the dot of «ذهب»);
- its code of the kind the setting says -- DataMatrix, QR, Aztec or Code 128 -- each within its face;
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
    """(x, y, h) of the field drawn with *command* (^BXN / ^A0N / ^A@I)."""
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


def test_the_first_face_its_code_number_karat_weight_and_stones():
    zpl = _zpl(stones=0.35)
    assert '^BXN,6,200,14,14^FDKJ-000124^FS' in zpl, 'the DataMatrix of its number, 14 x 14 cells'
    assert '^BQN' not in zpl, 'not a QR'
    x, y, _ = _field(zpl, '^BXN')
    assert L.TOP + L.MARGIN <= y and y + L.CODE_SIDE <= L.TOP + L.FACE_H - L.MARGIN, 'not across the fold'
    assert L.MARGIN <= x and x + L.CODE_SIDE <= L.FACE_W - L.MARGIN
    assert '^FDKJ-000124^FS' in zpl and '^FD21K · 12.40g^FS' in zpl
    stones = re.search(r'\^FO\d+,(\d+)\^A0N,(\d+),\d+\^FB\d+,1,0,C\^FDSt 0\.35g\^FS', zpl)
    assert stones, 'the stones on the first face, in Latin symbols'
    y, h = int(stones.group(1)), int(stones.group(2))
    assert y + h <= L.TOP + L.FACE_H - L.MARGIN, 'within the first face'


def _second_face_fields(zpl):
    """(y, h, text) of each line drawn in Cairo -- the second face's."""
    return [(int(y), int(h), t) for y, h, t in
            re.findall(r'\^FO\d+,(\d+)\^A@N,(\d+),\d+,E:CAIRO\.TTF\^FB\d+,1,0,C\^FD([^\^]*)\^FS', zpl)]


def test_the_second_face_upright_the_name_above_the_chips_bump_the_size_at_its_foot():
    """The owner's prints of 27 Nov 2026: the name 3 mm lower than first printed, the size 1 mm above
    the face's bottom edge -- the bump, a millimetre wide, between them."""
    second = L.TOP + L.FACE_H
    bump_top, bump_bottom = second + L.BUMP_Y - L.BUMP_R, second + L.BUMP_Y + L.BUMP_R
    for facts in ({'name': 'بناجر ذهب 21', 'size': '18'}, {'name': 'بناجر ذهب 21'}, {'size': '18'},
                  {'name': 'طقم ذهب إيطالي مرصع بفصوص زركون ملونة كبير', 'size': '18', 'stones': 0.35}):
        fields = {t: (y, h) for y, h, t in _second_face_fields(_zpl(**facts))}
        names = [(y, h) for t, (y, h) in fields.items() if not t.startswith('Sz')]
        for y, h in names:
            assert y == second + L.NAME_Y, f'the name 3 mm lower than first printed: {facts}'
            assert y + h <= bump_top - L.BUMP_CLEAR, f'the name above the bump, a margin kept: {facts}'
        if 'size' in facts:
            y, h = fields['Sz 18']
            assert y + h == second + L.FACE_H - L.SIZE_FOOT, 'the size 1 mm above the bottom edge'
            assert y >= second + L.BUMP_Y, 'its letters under the bump: its line\'s top is Cairo\'s empty ascent'
            assert all(ny + nh <= y for ny, nh in names), 'the size under the name'
    assert '^A@I' not in _zpl(name='بناجر ذهب 21', size='18'), 'upright, from the tail: not turned over'
    assert 'St ' not in ''.join(t for *_, t in _second_face_fields(_zpl(name='x', stones=0.35, size='18'))), \
        'the stones are the first face\'s'


def test_each_mark_only_when_the_piece_has_it():
    assert 'St ' not in _zpl(stones=0.0) and 'Sz ' not in _zpl(size='')
    assert '^FDSz 18^FS' in _zpl(size='18') and '^FDSt 1.20g^FS' in _zpl(stones=1.2)
    assert '^A@' not in _zpl(), 'no name, no size: nothing on the second face'


@pytest.mark.parametrize('kind, command', [('datamatrix', '^BXN,6,200,14,14^FDKJ-000124^FS'),
                                           ('qr', '^BQN,2,4^FDMA,KJ-000124^FS'),
                                           ('aztec', '^BON,4,N,102,N,1^FDKJ-000124^FS'),
                                           ('code128', '^BCN,40,N,N,N,A^FDKJ-000124^FS')])
def test_its_code_in_the_kind_the_setting_says_holding_its_number(kind, command):
    """The owner, 27 Nov 2026: «اعداد لتحديد اي رمز يطبع QR, DM, BC وغيرها» -- one code a label, of its kind."""
    zpl = _zpl(code_type=kind, stones=0.35)
    assert command in zpl
    others = {'^BXN', '^BQN', '^BON', '^BCN'} - {command[:4]}
    assert not any(o in zpl for o in others), 'one code, not two'
    assert zpl.count('^FDKJ-000124^FS') + zpl.count('^FDMA,KJ-000124^FS') == 2, 'the code and the number'


@pytest.mark.parametrize('kind', ['datamatrix', 'qr', 'aztec'])
def test_a_square_code_within_its_face_its_words_beside_it(kind):
    zpl = _zpl(code_type=kind, stones=0.35)
    side = L.SQUARE_SIDE[kind]
    code = re.search(r'\^FO(\d+),(\d+)\^B[XQO]N', zpl)
    x, y = int(code.group(1)), int(code.group(2))
    drawn = y + (L.QR_DROP if kind == 'qr' else 0)               # where the printer draws it
    assert L.MARGIN <= x and x + side <= L.FACE_W - L.MARGIN
    assert L.TOP + L.MARGIN <= drawn and drawn + side <= L.TOP + L.FACE_H - L.MARGIN, 'not across the fold'
    for wx, wy, wh in re.findall(r'\^FO(\d+),(\d+)\^A0N,(\d+)', zpl):
        assert int(wx) >= x + side + L.MARGIN, 'the words beside the code, not over it'
        assert int(wy) + int(wh) <= L.TOP + L.FACE_H - L.MARGIN
    assert drawn == L.TOP + (L.FACE_H - side) // 2, \
        'in the middle of its face -- a QR placed higher, the printer drawing it lower (the owner, 27 Nov)'
    assert y >= 0, 'its origin on the label'


def test_code_128_a_bar_across_the_face_its_words_under_it():
    zpl = _zpl(code_type='code128', stones=0.35)
    assert '^BY2,3,40' in zpl, 'its narrowest bar two dots, 40 high'
    x, y = map(int, re.search(r'\^FO(\d+),(\d+)\^BCN', zpl).groups())
    bars = L.bar_width('KJ-000124') - 2 * L.BAR_QUIET
    assert x - L.BAR_QUIET >= 0 and x + bars + L.BAR_QUIET <= L.FACE_W, 'its quiet zones within the face'
    assert y == L.TOP + L.MARGIN + L.BAR_DROP, 'the bar as low as its words let it (the owner, 27 Nov)'
    words = [(int(wy), int(wh)) for wy, wh in re.findall(r'\^FO\d+,(\d+)\^A0N,(\d+)', zpl)]
    assert len(words) == 3 and all(wy >= y + L.BAR_H for wy, _ in words), 'the number, facts and stones under it'
    assert '^FDSt 0.35g^FS' in zpl, 'the stones under the weight, a line of their own'
    assert max(wy + wh for wy, wh in words) == L.TOP + L.FACE_H - L.MARGIN, 'down to the face\'s lower margin'


def test_code_128_takes_the_numbers_the_face_holds_and_refuses_a_longer():
    assert L.bar_width('KJ-000001') == 264 and L.bar_width('KJ-10000005') <= L.FACE_W
    assert '^BCN' in L.label_zpl('KJ-10000005', code_type='code128')
    with pytest.raises(ValueError, match='Code 128'):
        L.label_zpl('KJ-100000005', code_type='code128')
    assert '^BXN' in L.label_zpl('KJ-100000005'), 'a square code holds it'


def test_no_code_kind_but_the_four():
    assert L.code_kind(None) == L.code_kind('') == 'datamatrix', 'nothing set: what was printed before'
    assert L.code_kind(' QR ') == 'qr'
    for kind in ('code39', 'ean13', 'pdf417'):
        with pytest.raises(ValueError):
            L.label_zpl('KJ-000124', code_type=kind)


def test_a_framed_test_label_draws_the_chips_bump():
    zpl = L.label_zpl('KJ-999999', write_tag=False, frame=True)
    second = L.TOP + L.FACE_H
    assert f'^FO0,{second + L.BUMP_Y - L.BUMP_R}^GB{L.FACE_W},{2 * L.BUMP_R},1^FS' in zpl
    assert '^RFW' not in zpl, 'no tag written'


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


def test_its_code_holds_its_number_or_refuses():
    """14 x 14 cells hold «KJ-» and ten digits: a longer number would print an empty code -- refused."""
    assert '^FDKJ-1234567890^FS' in L.label_zpl('KJ-1234567890')
    with pytest.raises(ValueError):
        L.label_zpl('KJ-12345678901')
