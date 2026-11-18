"""Sales analysis by the model and the size (ADR-093; the owner, 18 Nov 2026).

«هل ستتبع التقارير حركة الموديل؟» -- the analysis grouped by category, item
and karat, not by model. Now by model or size too: each group its value, its
grams, its pieces sold less those returned; a line sold by weight, or a piece
without a model, «بلا موديل»; a size named with its system.

Run:
    python -m pytest tests/test_sales_by_model.py -v
"""
import datetime as dt
import uuid

from models import Invoice, InvoiceItem, db
from services.pieces import register_piece
from services.reports.sales_analysis import sales_analysis
from tests.test_piece_model_station import sized  # noqa: F401
from tests.test_piece_registration import bangles_by_the_piece  # noqa: F401
from tests.test_receiving_correction import _received, showroom  # noqa: F401
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401

DAY = dt.datetime(2097, 3, 10, 12)


def _sale(lines, *, kind='بيع'):
    total = sum(net for _, net, _ in lines)
    inv = Invoice(invoice_type=kind, invoice_type_id=900000 + uuid.uuid4().int % 99999, date=DAY, total=total,
                  is_posted=True, gold_type='new')
    db.session.add(inv)
    db.session.flush()
    for piece, net, weight in lines:
        db.session.add(InvoiceItem(invoice_id=inv.id, item_id=piece.id if piece else None, name='بيع', quantity=1,
                                   price=net, net=net, karat=21, weight=weight,
                                   category_id=piece.category_id if piece else None))
    db.session.flush()
    return inv


def _rows(by):
    report = sales_analysis(now=NOW, start=DAY.date(), end=DAY.date(), by=by).to_dict()
    return {r['group']: r for r in report['rows']}, [c['key'] for c in report['columns']]


def test_by_model_and_size_each_its_pieces_value_and_grams(sized):
    model, sizes = sized['model'], sized['sizes']
    a = register_piece(sized['line'], weight=10.0, model_id=model.id, size_id=sizes['18'].id, by='t', now=NOW)
    b = register_piece(sized['line'], weight=8.0, model_id=model.id, size_id=sizes['17'].id, by='t', now=NOW)
    plain = register_piece(sized['line'], weight=5.0, by='t', now=NOW)
    _sale([(a, 5000.0, 10.0), (b, 4000.0, 8.0)])
    _sale([(plain, 2500.0, 5.0), (None, 1000.0, 2.0)])
    _sale([(b, 4000.0, 8.0)], kind='مرتجع بيع')

    by_model, columns = _rows('model')
    assert 'pieces' in columns
    sun = by_model['بنجرة الشمس']
    assert (sun['pieces'], sun['weight']) == (1, 10.0), 'two sold, one returned'
    assert by_model['بلا موديل']['pieces'] == 1, 'a piece without a model; a line by weight is no piece'
    by_size, _ = _rows('size')
    label = next(g for g in by_size if g.startswith('18 ('))
    assert by_size[label]['pieces'] == 1 and by_size[label]['weight'] == 10.0
    assert by_size['بلا مقاس']['pieces'] == 1
