"""A return gives back of each line no more than remains of it (the owner, 11 Nov 2026).

The return audit (docs/plans/returns-audit-2026-11.md), proven on the 10 Nov
copy:
- a line was returned whole three times (3779, 1.6 g): each request was set
  against its original line alone, never against the returns before it --
  the return line's link to its line was checked and thrown away;
- a line of 32.1 g for two pieces gave back 45 g: the line's cap multiplied
  its weight by its count, though a line's weight is the whole line's;
- a part of a rejected, never-posted sale was returned and posted: 5,700 out,
  its weight into the stock (the whole reversal refuses it, the partial did not);
- the check was in a try/except that let the return through on any error.

Now the link is kept on the return's line, what remains of a line is its
grams (its pieces where it has no weight) less every return before that was
not rejected -- one return no more pieces than were sold -- a
customer's return needs a posted original, and a check that fails refuses.
The 68 sales of Mar-Apr 2026 that kept a piece's weight on the line (their
invoice weight the lines' weights by their counts) are read so.

Run:
    python -m pytest tests/test_return_line_remaining.py -v
"""
import pytest

from flask import g

from app import app as flask_app
from models import Invoice, InvoiceItem, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


LINES = [  # name, weight of the line, pieces, price
    ('خاتم', 2.0, 1, 1000.0),
    ('بنجرة', 10.0, 5, 5000.0),
    ('طقم', 40.0, 1, 20000.0),
]


def _post(headers, payload):
    g.pop('current_user', None)   # the module's app context keeps the last request's user
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def _sale(headers, world, *, held=False):
    """A sale of three lines, 52 g for 26,000.00, paid in cash (held: waiting
    for its approval, not posted)."""
    total = sum(p for *_, p in LINES)
    payload = {
        'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'employee_id': world['holder'].id, 'date': __import__('datetime').datetime.now().isoformat(),
        'total': total, 'total_weight': sum(w for _, w, _, _ in LINES), 'total_tax': 0.0, 'total_cost': 0.0,
        'amount_paid': total, 'payments': [{'payment_method_id': world['pm'].id, 'amount': total}],
        'items': [{'name': n, 'karat': 21, 'weight': w, 'quantity': q, 'price': p, 'net': p, 'wage': 0,
                   'selling_price': p, 'discount_amount': (0.4 * p if held else 0.0)} for n, w, q, p in LINES],
    }
    resp = _post(headers, payload)
    assert resp.status_code == 201, resp.get_json()
    sale = resp.get_json()
    assert bool(sale['is_posted']) is (not held)
    return sale


def _line(sale, name):
    return next(i for i in sale['items'] if i['name'] == name)


def _return(world, sale, lines):
    """A return of [(name, weight, pieces, price)] of the sale's lines."""
    items = [{'name': n, 'karat': 21, 'weight': w, 'quantity': q, 'price': p, 'net': p, 'wage': 0, 'tax': 0,
              'original_invoice_item_id': _line(sale, n)['id']} for n, w, q, p in lines]
    total = sum(p for *_, p in lines)
    return {
        'invoice_type': 'مرتجع بيع', 'customer_id': world['customer'].id, 'original_invoice_id': sale['id'],
        'gold_type': 'new', 'branch_id': sale.get('branch_id'), 'date': sale['date'], 'return_reason': 'عيب',
        'total': total, 'total_weight': sum(w for _, w, _, _ in lines), 'total_tax': 0.0, 'amount_paid': total,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': total}], 'items': items,
    }


def _refused(resp, code):
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == code, resp.get_json()


def test_a_line_is_not_returned_twice(auth_headers, world):
    sale = _sale(auth_headers, world)
    assert _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)])).status_code == 201
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    _refused(resp, 'return_line_exceeds_remaining')
    body = resp.get_json()
    assert body['line'] == 'خاتم' and body['remaining_grams'] == 0.0


def test_what_remains_of_a_line_is_taken_in_parts(auth_headers, world):
    sale = _sale(auth_headers, world)
    for _ in range(2):
        resp = _post(auth_headers, _return(world, sale, [('بنجرة', 4.0, 2, 2000.0)]))
        assert resp.status_code == 201, resp.get_json()
    _refused(_post(auth_headers, _return(world, sale, [('بنجرة', 4.0, 2, 2000.0)])), 'return_line_exceeds_remaining')
    resp = _post(auth_headers, _return(world, sale, [('بنجرة', 2.0, 1, 1000.0)]))
    assert resp.status_code == 201, resp.get_json()


def test_a_line_gives_back_no_more_than_its_own_weight(auth_headers, world):
    """10 g for five pieces: not 50 (10 x 5), though the invoice's 52 would hold it."""
    sale = _sale(auth_headers, world)
    _refused(_post(auth_headers, _return(world, sale, [('بنجرة', 30.0, 1, 1000.0)])), 'return_line_exceeds_remaining')


def test_a_line_comes_back_by_its_weight_its_count_as_sent(auth_headers, world):
    """The screen sends the line's count with a part of its weight: what remains
    is its grams (RETURN-LIMIT-1), never refused for pieces sent before."""
    sale = _sale(auth_headers, world)
    assert _post(auth_headers, _return(world, sale, [('بنجرة', 4.0, 5, 2000.0)])).status_code == 201
    resp = _post(auth_headers, _return(world, sale, [('بنجرة', 6.0, 5, 3000.0)]))
    assert resp.status_code == 201, resp.get_json()
    _refused(_post(auth_headers, _return(world, sale, [('بنجرة', 0.5, 1, 100.0)])), 'return_line_exceeds_remaining')


def test_one_return_gives_back_no_more_pieces_than_were_sold(auth_headers, world):
    sale = _sale(auth_headers, world)
    _refused(_post(auth_headers, _return(world, sale, [('بنجرة', 4.0, 6, 2000.0)])), 'return_quantity_exceeds_original')


def test_the_return_line_keeps_its_line(auth_headers, world):
    sale = _sale(auth_headers, world)
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert resp.status_code == 201, resp.get_json()
    line = InvoiceItem.query.filter_by(invoice_id=resp.get_json()['id']).one()
    assert line.original_invoice_item_id == _line(sale, 'خاتم')['id']


def test_a_rejected_return_gives_its_line_back(auth_headers, world):
    sale = _sale(auth_headers, world)
    first = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert first.status_code == 201
    rejected = db.session.get(Invoice, first.get_json()['id'])
    rejected.status = 'rejected'
    db.session.flush()
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert resp.status_code == 201, resp.get_json()


def test_a_sale_not_posted_is_not_returned_in_part(auth_headers, world):
    sale = _sale(auth_headers, world, held=True)
    _refused(_post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 600.0)])), 'original_not_posted')


def test_a_sale_that_kept_a_piece_s_weight_is_read_so(auth_headers, world):
    """Mar-Apr 2026: the line's weight a piece's, the invoice's the lines' by their counts."""
    sale = _sale(auth_headers, world)
    line = db.session.get(InvoiceItem, _line(sale, 'بنجرة')['id'])
    line.weight = 2.0                                   # a piece of five
    original = db.session.get(Invoice, sale['id'])
    original.total_weight = 2.0 + 2.0 * 5 + 40.0
    db.session.flush()
    _refused(_post(auth_headers, _return(world, sale, [('بنجرة', 10.5, 5, 5000.0)])), 'return_line_exceeds_remaining')
    resp = _post(auth_headers, _return(world, sale, [('بنجرة', 10.0, 5, 5000.0)]))
    assert resp.status_code == 201, resp.get_json()


def test_a_check_that_fails_refuses(auth_headers, world, monkeypatch):
    sale = _sale(auth_headers, world)
    from services import return_lines

    def broken(*args, **kwargs):
        raise RuntimeError('a fault in the check')

    monkeypatch.setattr(return_lines, 'refuse_return_lines', broken)
    resp = _post(auth_headers, _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert resp.status_code != 201, 'never saved past a check that did not run'
