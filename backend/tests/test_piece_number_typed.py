"""A piece's number as it is typed (the owner, 21 Nov 2026: «رمز بادئة رقم
الصنف اختياري ... يتم كتابة الرقم ١ فيتم التعرف على القطعة»).

- One reading (services/pieces.piece_code): «1», «١», «000001», «kj-1» and
  «KJ-000001» are all KJ-000001; a number longer than six digits as it is;
  nothing that is not a number.
- Wherever a piece's number is typed -- the lookup the sale and the transfer
  ask, a transfer's named pieces, «القطع»'s search -- it is read so, and a
  number alone is never an id.

Run:
    python -m pytest tests/test_piece_number_typed.py -v
"""
import pytest

from models import Item, db
from services.pieces import PieceRefused, piece_code, pieces_list, refuse_piece_transfer
from tests.test_melting_and_renewal_go_one_way import _safe
from tests.test_piece_transfer import _bangles, _behind_the_fence, _pieces  # noqa: F401
from tests.test_stock_count import NOW


@pytest.mark.parametrize('typed, code', [
    ('1', 'KJ-000001'), ('١', 'KJ-000001'), ('۱', 'KJ-000001'), ('000001', 'KJ-000001'), ('kj-1', 'KJ-000001'),
    ('KJ1', 'KJ-000001'), (' KJ-000001 ', 'KJ-000001'), ('١٢', 'KJ-000012'), ('1234567', 'KJ-1234567'),
    ('0', None), ('000000', None), ('12a', None), ('KJ-', None), ('بنجرة', None), ('', None), (None, None),
])
def test_one_reading_of_a_typed_piece_number(typed, code):
    assert piece_code(typed) == code


def _number(piece):
    return str(int(piece.item_code[3:]))


def test_the_lookup_reads_a_number_alone_as_the_piece_s(app, auth_headers):
    from flask import g
    from tests.test_wage_treatment_follows_the_setting import flask_app
    box = _safe('showroom')
    a, = _pieces(box, _bangles(), 10.0)
    db.session.commit()
    client = flask_app.test_client()
    for typed in (_number(a), _number(a).translate(str.maketrans('0123456789', '٠١٢٣٤٥٦٧٨٩')), a.item_code.lower()):
        g.pop('current_user', None)
        r = client.get('/api/pieces/lookup', query_string={'code': typed}, headers=auth_headers)
        assert r.status_code == 200 and r.get_json()['piece']['item_code'] == a.item_code, typed
    g.pop('current_user', None)
    gone = client.get('/api/pieces/lookup', query_string={'code': '999999999'}, headers=auth_headers)
    assert (gone.status_code, gone.get_json()['message']) == (404, 'لا قطعة بالرقم KJ-999999999')


def test_a_transfer_s_number_is_the_piece_s_never_an_id():
    from models import PIECE_NUMBER
    box, other = _safe('showroom'), _safe('showroom', 'معرض الفرع')
    db.session.execute(PIECE_NUMBER.next_value())                 # a number used: numbers and ids part
    a, = _pieces(box, _bangles(), 10.0)
    assert str(a.id) != _number(a), 'the test needs a piece whose id is not its number'
    assert [p.id for p in refuse_piece_transfer(box, other, [_number(a)], {21: 10.0})] == [a.id], \
        'its number names it; read as an id it named another item or none'


def test_the_pieces_list_reads_a_number_alone_as_one_piece():
    box = _safe('showroom')
    a, b = _pieces(box, _bangles(), 10.0, 11.0)
    b.item_code = f'KJ-{int(_number(a) * 2):06d}'                # a code that holds a's digits
    db.session.flush()
    found = pieces_list(q=_number(a), state='all', today=NOW)['pieces']
    assert [p['item_code'] for p in found] == [a.item_code], 'that piece, not every code holding its digits'
