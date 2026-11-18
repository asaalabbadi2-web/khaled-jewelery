"""The models' movement in a period (ADR-093; the owner, 18 Nov 2026).

Each model and size: what was in the stock at the period's start, what was
received, what came back, what was sold, returned to its supplier or went
out otherwise, and what is left -- from the books' allocations alone. The
laws: a move between two safes in one entry is no movement; what was, plus
what came in, less what went out, is what is left; a piece outside the
period's moves and stock is not listed.

Run:
    python -m pytest tests/test_model_movement.py -v
"""
import datetime as dt
import uuid

from models import Invoice, JournalEntry, JournalEntryLine, SafeBox, db
from services.pieces import register_piece
from services.reports.model_movement import model_movement
from services.stock_ledger import allocate
from tests.test_piece_model_station import sized  # noqa: F401
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401


def _move(piece, lines, *, kind, when):
    """An entry of an invoice of *kind* moving *piece*: [(safe, grams signed)]."""
    doc = Invoice(invoice_type=kind, invoice_type_id=800000 + uuid.uuid4().int % 99999, date=when, total=0.0)
    db.session.add(doc)
    db.session.flush()
    entry = JournalEntry(entry_number=f'JE-MM-{uuid.uuid4().hex[:8]}', date=when, description=kind,
                         entry_type='عادي', is_posted=True, is_draft=False, created_by='t',
                         reference_type='invoice', reference_id=doc.id)
    db.session.add(entry)
    db.session.flush()
    for safe, grams in lines:
        line = JournalEntryLine(journal_entry_id=entry.id, account_id=safe.account_id, description=kind,
                                **({'debit_21k': grams} if grams > 0 else {'credit_21k': -grams}))
        db.session.add(line)
        db.session.flush()
        allocate(line, 21, piece.category_id, grams, item_id=piece.id, by='t', now=NOW)


def _vault():
    """A second stock safe of the test's own: a move to it is a transfer."""
    from models import Account
    account = Account(account_number=f'9V{uuid.uuid4().hex[:6]}', name='خزينة اختبار', type='Asset',
                      tracks_weight=True, transaction_type='gold')
    db.session.add(account)
    db.session.flush()
    safe = SafeBox(name=f'خزينة {uuid.uuid4().hex[:5]}', safe_type='gold', account_id=account.id, is_active=True,
                   stock_location='vault')
    db.session.add(safe)
    db.session.flush()
    return safe


def _rows(report):
    return {(r['model'], r.get('size')): r for r in report.to_dict()['rows']}


def test_each_model_and_size_from_the_start_to_what_is_left(sized, showroom):
    model, sizes = sized['model'], sized['sizes']
    a = register_piece(sized['line'], weight=10.0, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
    b = register_piece(sized['line'], weight=8.0, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
    c = register_piece(sized['line'], weight=6.0, model_id=model.id, size_id=sizes['17'].id, by='t', now=NOW)
    loose = register_piece(sized['line'], weight=3.0, by='t', now=NOW)
    vault = _vault()
    born = sized['invoice'].date
    day = lambda d: born + dt.timedelta(days=d)              # noqa: E731
    _move(a, [(showroom, -10.0)], kind='بيع', when=day(3))
    _move(a, [(showroom, 10.0)], kind='مرتجع بيع', when=day(4))
    _move(b, [(showroom, -8.0)], kind='مرتجع شراء (مورد)', when=day(5))
    _move(c, [(showroom, -6.0), (vault, 6.0)], kind='نقل', when=day(6))      # a transfer: no movement
    _move(c, [(vault, -6.0)], kind='بيع', when=day(20))                      # after the period

    mine = sized['category'].id                   # other tests' pieces live in other categories
    report = model_movement(now=NOW, start=born.date(), end=day(10).date(), category_id=mine)
    rows = _rows(report)
    eighteen = rows[('بنجرة الشمس', '18')]
    assert {k: eighteen[k] for k in ('opening', 'received', 'came_back', 'sold', 'returned', 'out', 'closing')} == \
        {'opening': 0, 'received': 2, 'came_back': 1, 'sold': 1, 'returned': 1, 'out': 0, 'closing': 1}
    assert eighteen['closing_weight'] == 10.0
    seventeen = rows[('بنجرة الشمس', '17')]
    assert (seventeen['received'], seventeen['out'], seventeen['closing']) == (1, 0, 1), 'a transfer is no move'
    assert rows[('بلا موديل', 'بلا مقاس')]['closing'] == 1
    assert {c.key: c.ok for c in report.checks}['balance'] is True

    later = _rows(model_movement(now=NOW, start=day(11).date(), end=day(30).date(), category_id=mine))
    assert later[('بنجرة الشمس', '17')]['opening'] == 1 and later[('بنجرة الشمس', '17')]['sold'] == 1
    assert ('بنجرة الشمس', '18') in later, 'still one in the stock: listed'

    by_model = _rows(model_movement(now=NOW, start=born.date(), end=day(10).date(), by='model', category_id=mine))
    assert by_model[('بنجرة الشمس', None)]['received'] == 3


def test_the_route_carries_it(sized, auth_headers):
    from flask import g
    from app import app as flask_app
    register_piece(sized['line'], weight=5.0, model_id=sized['model'].id, by='t', now=NOW)
    when = sized['invoice'].date.date().isoformat()
    g.pop('current_user', None)
    reply = flask_app.test_client().get(f'/api/reports/model-movement?start_date={when}&end_date={when}'
                                        f"&category_id={sized['category'].id}", headers=auth_headers)
    assert reply.status_code == 200, reply.get_data(as_text=True)[:300]
    body = reply.get_json()
    assert body['id'] == 'model_movement' and body['totals']['received'] == 1
    g.pop('current_user', None)
    assert flask_app.test_client().get('/api/reports/model-movement', headers=auth_headers).status_code == 400
