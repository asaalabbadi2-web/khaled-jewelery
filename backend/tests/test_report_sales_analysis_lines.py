"""Sales analysis by category, karat and gold type, and the last sale (REPORTS ت4-1, ADR-083).

The old sales reports merge into the one analysis (the owner, 4 Nov 2026).
A sale's lines carry no item (2,905 of 2,906 on the 2 Nov copy) but a
category and a karat, and their value before VAT (`net`: October's sum is the
invoices' to the halala). So by category or karat a document's value is shared
on its lines by their `net` -- the document's value stays the one the books
agree with -- each line's grams in the main karat; a line with no category is
«بلا تصنيف». Gold type is the document's own (new, scrap). By customer or
category a row says its last sale -- a date, never the table's wide column.

Run:
    python -m pytest tests/test_report_sales_analysis_lines.py -v
"""
import datetime as dt
import uuid

import pytest

from models import Category, Invoice, db
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_weight_position import _post

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _sale(headers, world, when, lines, gold_type='new', kind='بيع'):
    """*lines*: [(net, karat, weight, category id | None)]."""
    total = sum(net for net, *_ in lines)
    return _post(headers, {
        'customer_id': world['customer'].id, 'invoice_type': kind, 'gold_type': gold_type,
        'date': when.isoformat(), 'total': total, 'total_weight': sum(w for _, _, w, _ in lines),
        'total_tax': 0.0, 'amount_paid': total, 'payments': [{'payment_method_id': world['pm'].id, 'amount': total}],
        'items': [{'name': 'قطعة', 'karat': karat, 'weight': weight, 'price': net, 'net': net, 'quantity': 1,
                   'wage': 0, 'selling_price': net, 'category_id': category}
                  for net, karat, weight, category in lines]})


@pytest.fixture
def sold(auth_headers, world):
    rings = Category(name=f'خواتم {uuid.uuid4().hex[:6]}')
    chains = Category(name=f'سلاسل {uuid.uuid4().hex[:6]}')
    db.session.add_all([rings, chains])
    db.session.commit()
    first = _sale(auth_headers, world, D(2041, 6, 3, 10), [(600.0, 21, 2.0, rings.id), (400.0, 18, 1.0, chains.id)])
    second = _sale(auth_headers, world, D(2041, 6, 20, 10), [(300.0, 21, 1.0, rings.id), (100.0, 21, 0.4, None)])
    scrap = _sale(auth_headers, world, D(2041, 6, 25, 10), [(200.0, 21, 1.0, None)], gold_type='scrap')
    return {'rings': rings, 'chains': chains, 'first': first, 'second': second, 'scrap': scrap}


def _analysis(by):
    from services.reports.sales_analysis import sales_analysis
    return sales_analysis(now=D(2041, 7, 1), start=dt.date(2041, 6, 1), end=dt.date(2041, 6, 30), by=by)


def _rows(report):
    return {r['group']: r for r in report.rows}


def test_by_karat_each_line_s_share_and_grams(sold):
    report = _analysis('karat')
    rows = _rows(report)
    assert rows['عيار 21']['value'] == pytest.approx(600.0 + 300.0 + 100.0 + 200.0)
    assert rows['عيار 21']['weight'] == pytest.approx(2.0 + 1.0 + 0.4 + 1.0)
    assert rows['عيار 18']['value'] == pytest.approx(400.0)
    assert rows['عيار 18']['weight'] == pytest.approx(18 / 21, abs=1e-3), 'in the main karat'
    assert rows['عيار 21']['invoices'] == 3 and rows['عيار 18']['invoices'] == 1, 'a document once in each group'
    assert report.totals['value'] == pytest.approx(1600.0)
    assert {c.key: c.ok for c in report.checks} == {'books_agree': True}
    assert rows['عيار 18']['per_gram'] == pytest.approx(400.0 / (18 / 21), abs=0.01)


def test_by_category_and_the_lines_with_none(sold):
    rows = _rows(_analysis('category'))
    assert rows[sold['rings'].name]['value'] == pytest.approx(900.0)
    assert rows[sold['chains'].name]['value'] == pytest.approx(400.0)
    assert rows['بلا تصنيف']['value'] == pytest.approx(300.0)
    assert rows[sold['rings'].name]['drill'] is None


def test_by_gold_type_the_document_s_own(sold):
    rows = _rows(_analysis('gold_type'))
    assert rows['ذهب جديد']['value'] == pytest.approx(1400.0)
    assert rows['كسر']['value'] == pytest.approx(200.0)


def test_a_document_s_value_is_shared_by_its_lines_net(sold):
    """The document's value (less its posted VAT) is what the books agree with;
    its lines share it by their net."""
    inv = db.session.get(Invoice, sold['first'])
    inv.total = 1100.0                          # the document says more than its lines
    db.session.flush()
    rows = _rows(_analysis('karat'))
    assert rows['عيار 18']['value'] == pytest.approx(1100.0 * 400.0 / 1000.0)


def test_the_last_sale_by_customer_and_category(sold):
    report = _analysis('category')
    assert _rows(report)[sold['chains'].name]['last'] == '2041-06-03'
    assert _rows(report)[sold['rings'].name]['last'] == '2041-06-20'
    assert {c.key: c.kind for c in report.columns}['last'] == 'date'
    assert next(iter(_analysis('customer').rows))['last'] == '2041-06-25'
    assert 'last' not in {c.key for c in _analysis('month').columns}


def test_by_item_the_piece_and_the_lines_by_weight(sold):
    """The owner, 4 Nov 2026: from 2027 a sale records its piece (ADR-045, piece
    tracking category by category); a line sold by weight has none."""
    from models import InvoiceItem, Item
    piece = Item(item_code=f'I-SA{uuid.uuid4().hex[:6]}', name='خاتم سوليتير', karat='21', weight=2.0, price=0.0)
    db.session.add(piece)
    db.session.flush()
    line = InvoiceItem.query.filter_by(invoice_id=sold['first'], karat=21).one()
    line.item_id = piece.id
    db.session.flush()
    report = _analysis('item')
    rows = _rows(report)
    assert rows[f'خاتم سوليتير ({piece.item_code})']['value'] == pytest.approx(600.0)
    assert rows['بلا صنف (بالوزن)']['value'] == pytest.approx(1000.0)
    assert {c.key for c in report.columns} >= {'per_gram', 'last'}
    assert {c.key: c.ok for c in report.checks} == {'books_agree': True}


def test_by_day_or_month_it_asks_for_a_chart_of_its_value(sold):
    """REPORTS ت4-2 (the owner, 4 Nov 2026: a chart in the shell): a report
    over time names its chart -- its x, its figure -- and the shell draws it."""
    assert _analysis('month').to_dict()['chart'] == {'x': 'group', 'y': 'value'}
    assert _analysis('category').to_dict()['chart'] is None


def test_a_chart_names_the_report_s_own_columns():
    from services.reports.contract import Chart, Column, Report
    with pytest.raises(ValueError):
        Report(id='x', title='x', basis='documents', columns=[Column('group', 'g'), Column('value', 'v', 'money')],
               rows=[], totals={}, read_at=D(2041, 7, 1), chart=Chart('group', 'nothing'))
    with pytest.raises(ValueError):
        Report(id='x', title='x', basis='documents', columns=[Column('group', 'g'), Column('value', 'v', 'money')],
               rows=[], totals={}, read_at=D(2041, 7, 1), chart=Chart('group', 'group'))
