"""A piece weighed on the scale, in the books (the owner, 20 Nov 2026).

The station types what the scale says -- the piece's standing weight -- and
its stones. What that is in the books is the server's one reading
(services/pieces.weigh):

- a receipt line whose stones are priced by the carat (purchase_stones, ت4)
  holds its gold alone: its piece takes its net, standing less stones -- so
  the line is coded whole, and no piece carries gold the books do not have;
- a line whose stones count as gold -- every one today -- and a batch of the
  stock on hand hold the stones in their gold: the piece takes its standing;
- its weight in the books is what is sold as gold, and what its label and
  the screens show: its standing weight when its stones count as gold, «St»
  beside it; its net when they are priced apart, «+St» beside it -- the
  stones added, out of its weight (the owner, 20 Nov 2026);
- the station asks it before the press: the net, the rest after it, or the
  refusal the registration would meet -- nothing written.

Run:
    python -m pytest tests/test_piece_weighed.py -v
"""
import pytest

from models import Item, db
from services.pieces import PieceRefused, line_rest, piece_view, register_piece
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


@pytest.fixture
def line_of(world, auth_headers, showroom, bangles_by_the_piece):
    """A received line in a category tracked by the piece; its stones priced
    when asked -- the line's weight is then its gold alone (ت4)."""
    def _of(grams, *, priced=False):
        _, line = _received(auth_headers, world, grams)
        bangles_by_the_piece(line)
        if priced:
            line.stones_kind = 'priced'
            db.session.flush()
        return line
    return _of


def test_a_priced_line_s_piece_takes_its_net_and_the_line_is_coded_whole(line_of):
    line = line_of(24.10, priced=True)
    first = register_piece(line, weight=12.40, stones_weight=0.35, by='t', now=NOW)
    second = register_piece(line, weight=12.40, stones_weight=0.35, by='t', now=NOW)
    assert (first.weight, first.stones_weight) == (12.05, 0.35), 'its gold, its stones beside it'
    assert second.weight == 12.05
    assert line_rest(line) == 0.0, 'two pieces of 12.05 gold: the line\'s 24.10 coded whole'


def test_a_line_whose_stones_are_gold_gives_its_piece_its_standing_weight(line_of):
    line = line_of(20.0)
    piece = register_piece(line, weight=12.40, stones_weight=0.35, by='t', now=NOW)
    assert piece.weight == 12.40, 'the stones are in the line\'s gold: the piece takes them with it'
    assert line_rest(line) == 7.60
    view = piece_view(piece)
    assert (view['stones_kind'], view['standing_weight'], view['net_weight']) == ('as_gold', 12.40, 12.05)


def test_a_priced_piece_is_said_its_net_and_its_standing(line_of):
    line = line_of(20.0, priced=True)
    view = piece_view(register_piece(line, weight=12.40, stones_weight=0.35, by='t', now=NOW))
    assert (view['stones_kind'], view['weight'], view['standing_weight'], view['net_weight']) == \
        ('priced', 12.05, 12.40, 12.05)


def test_the_label_carries_what_is_sold_as_gold_and_marks_stones_out_of_it(line_of):
    from services.label_printing import label_facts
    from services.piece_label import label_faces
    within = label_facts(register_piece(line_of(20.0), weight=12.40, stones_weight=0.35, by='t', now=NOW))
    assert (within['weight'], within['stones'], within['stones_out']) == (12.40, 0.35, False), \
        'its stones counted as gold: sold at 12.40, never 12.05'
    out = label_facts(register_piece(line_of(20.0, priced=True), weight=12.40, stones_weight=0.35, by='t', now=NOW))
    assert (out['weight'], out['stones'], out['stones_out']) == (12.05, 0.35, True)
    within.pop('number'), out.pop('number')
    assert label_faces('KJ-000001', **within)['stones'] == 'St 0.35g'
    assert label_faces('KJ-000002', **out)['stones'] == '+St 0.35g'


def test_a_priced_piece_heavier_than_the_rest_is_said_by_its_gold(line_of):
    line = line_of(12.0, priced=True)
    with pytest.raises(PieceRefused) as refused:
        register_piece(line, weight=12.40, stones_weight=0.35, by='t', now=NOW)
    assert refused.value.code == 'piece_heavier_than_rest'
    assert 'ذهب القطعة (12.05 جم)' in refused.value.message


def test_the_station_asks_before_the_press_and_nothing_is_written(app, auth_headers, line_of):
    line = line_of(24.10, priced=True)
    client = app.test_client()
    r = client.get(f'/api/pieces/weigh?line_id={line.id}&weight=12.40&stones_weight=0.35', headers=auth_headers)
    assert r.status_code == 200, r.get_data(as_text=True)
    weighed = r.get_json()['weighed']
    assert (weighed['net_weight'], weighed['grams'], weighed['stones_kind'], weighed['rest_after']) == \
        (12.05, 12.05, 'priced', 12.05)
    r = client.get(f'/api/pieces/weigh?line_id={line.id}&weight=30&stones_weight=0', headers=auth_headers)
    body = r.get_json()
    assert r.status_code == 200 and body['weighed'] is None
    assert body['refused']['code'] == 'piece_heavier_than_rest'
    assert Item.query.filter_by(receipt_item_id=line.id).count() == 0, 'asked, not registered'
    r = client.get(f'/api/pieces/weigh?line_id={line.id}&weight=x', headers=auth_headers)
    assert r.get_json()['refused']['code'] == 'piece_weight_invalid'


def test_the_line_says_its_stones_kind(app, auth_headers, line_of):
    line = line_of(20.0, priced=True)
    r = app.test_client().get(f'/api/pieces/lines/{line.id}', headers=auth_headers)
    assert r.get_json()['line']['stones_kind'] == 'priced'
