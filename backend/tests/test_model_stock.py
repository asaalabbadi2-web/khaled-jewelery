"""The pieces that sit, and what to ask the supplier for (ADR-093; the owner, 18 Nov 2026).

From the books alone, as the models' movement reads them. The laws:
  - a piece sits from the last time it came into the stock -- a piece sold
    and come back sits from its coming back; a piece out of the stock does not;
  - a model's size is run out when none is held -- a size it names, or one
    it sold; short when its stock lasts less than the days read at the pace
    of those days; the loose pieces (no model) are no model's to reorder.

Run:
    python -m pytest tests/test_model_stock.py -v
"""
import datetime as dt

from services.pieces import register_piece
from services.reports.model_stock import ENOUGH, RUN_OUT, SHORT, model_reorder, slow_pieces
from tests.test_model_movement import _move
from tests.test_piece_model_station import sized  # noqa: F401
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _codes(report):
    return {r['item_code']: r for r in report.to_dict()['rows']}


def test_a_piece_sits_from_its_last_coming_into_the_stock(sized, showroom):
    model, sizes = sized['model'], sized['sizes']
    born = sized['invoice'].date
    day = lambda d: born + dt.timedelta(days=d)              # noqa: E731
    old = register_piece(sized['line'], weight=10.0, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
    sold = register_piece(sized['line'], weight=8.0, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
    back = register_piece(sized['line'], weight=6.0, model_id=model.id, size_id=sizes['17'].id, by='t', now=NOW)
    _move(sold, [(showroom, -8.0)], kind='بيع', when=day(3))
    _move(back, [(showroom, -6.0)], kind='بيع', when=day(10))
    _move(back, [(showroom, 6.0)], kind='مرتجع بيع', when=day(50))
    mine = sized['category'].id
    at = day(100).date()
    ninety = _codes(slow_pieces(now=NOW, as_of=at, min_days=90, category_id=mine))
    assert set(ninety) == {old.item_code} and ninety[old.item_code]['days'] == 100
    thirty = _codes(slow_pieces(now=NOW, as_of=at, min_days=30, category_id=mine))
    assert thirty[back.item_code]['days'] == 50, 'from its coming back'
    assert sold.item_code not in thirty
    by_model = slow_pieces(now=NOW, as_of=at, min_days=30, by='model', category_id=mine).to_dict()['rows']
    assert by_model == [{'model': 'بنجرة الشمس', 'pieces': 2, 'weight': 16.0, 'oldest': 100, 'average': 75}]


def test_what_to_ask_the_supplier_for(sized, showroom):
    model, sizes = sized['model'], sized['sizes']                      # it names 17 and 18
    born = sized['invoice'].date
    day = lambda d: born + dt.timedelta(days=d)              # noqa: E731
    pieces = [register_piece(sized['line'], weight=w, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
              for w in (5.0, 5.0, 5.0)]
    register_piece(sized['line'], weight=4.0, by='t', now=NOW)                 # loose: no model's
    _move(pieces[0], [(showroom, -5.0)], kind='بيع', when=day(5))
    _move(pieces[1], [(showroom, -5.0)], kind='بيع', when=day(10))
    rows = {r['size']: r for r in model_reorder(now=NOW, as_of=day(20).date(), days=30,
                                                category_id=sized['category'].id).to_dict()['rows']}
    assert (rows['18']['in_stock'], rows['18']['sold'], rows['18']['cover'], rows['18']['state']) == (1, 2, 15, SHORT)
    assert (rows['17']['in_stock'], rows['17']['state']) == (0, RUN_OUT), 'a size it names, none held'
    assert set(rows) == {'17', '18'}, 'the loose piece is no model\'s'
    calm = {r['size']: r for r in model_reorder(now=NOW, as_of=day(60).date(), days=30,
                                                category_id=sized['category'].id).to_dict()['rows']}
    assert calm['18']['state'] == ENOUGH and calm['18']['sold'] == 0, 'no sales in the days read: it lasts'


def test_the_routes_carry_them(sized, auth_headers):
    from flask import g
    from app import app as flask_app
    client = flask_app.test_client()
    for url in ('/api/reports/slow-pieces?min_days=30', '/api/reports/model-reorder?days=60'):
        g.pop('current_user', None)
        reply = client.get(url, headers=auth_headers)
        assert reply.status_code == 200, reply.get_data(as_text=True)[:200]
    g.pop('current_user', None)
    assert client.get('/api/reports/slow-pieces?min_days=7', headers=auth_headers).status_code == 400
