"""«تصحيح فاتورة» for a sale (ADR-056): its karat, weight or price put right by the difference.

Three of 2026's corrections were sales' (3427's prices, 3399's and 3442's
amounts), each a whole return and a re-entry. The sale's difference, one
entry dated the day:

  - the gold: the line as posted comes back into the safe it left (the
    showroom), the right lines leave it, against the customer's gold;
  - the price: the customer owes its difference, the sale earns it; its VAT
    at its own invoice's rate (the owner, 22 Oct 2026);
  - its wage released with the weight sold, when wages are capitalized;
  - its cost: the invoice's own a gram, so its profit -- what its points read
    (ت-2) -- is right; from the gold-cost day, the gold's cost written too;
  - a karat changed on a categorised line needs its new category.

Run:
    python -m pytest tests/test_invoice_correction_sale.py -v
"""
from datetime import date

import pytest

from accounting.chart_tree import role_account_id
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
from app import app as flask_app
from models import Account, Invoice, InvoiceCorrection, InvoiceItem, JournalEntryLine, SafeBox, Settings, db
from tests.test_gold_sold_at_its_cost import _sale, _square, world  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _sold(headers, w, **kw):
    resp = _sale(headers, w, **kw)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    invoice = Invoice.query.get(resp.get_json()['id'])
    return invoice, invoice.items[0]


def _correct(headers, invoice, line, lines, **body):
    payload = {'line_id': line.id, 'reason': 'تصحيح', 'lines': lines,
               'safe_box_id': body.pop('safe_box_id', None) or _showroom_safe().id, **body}
    return flask_app.test_client().post(f'/api/invoices/{invoice.id}/corrections', headers=headers, json=payload)


def _holds_18k(w, grams=20.0):
    """The piece sold as 21k was 18k: the showroom's books still hold it as 18k."""
    from tests.test_melting_and_renewal_go_one_way import _holds
    _holds(_showroom_safe(), 18, grams)


def _showroom_safe():
    stock = db.session.get(Account, role_account_id('gold_inventory_new'))
    return SafeBox.query.filter_by(account_id=stock.memo_account_id).one()


def _entry(resp):
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    correction = InvoiceCorrection.query.get(resp.get_json()['id'])
    return correction, JournalEntryLine.query.filter_by(journal_entry_id=correction.journal_entry_id,
                                                        is_deleted=False).all()


def _grams(lines, account_id):
    out = {}
    for l in lines:
        if l.account_id != account_id:
            continue
        for k in (18, 21, 22, 24):
            g = float(getattr(l, f'debit_{k}k') or 0) - float(getattr(l, f'credit_{k}k') or 0)
            if abs(g) > 1e-9:
                out[k] = round(out.get(k, 0.0) + g, 3)
    return {k: v for k, v in out.items() if abs(v) > 1e-9}


def _cash(lines, account_id):
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in lines if l.account_id == account_id), 2)


def test_a_karat_put_right_moves_the_showroom_and_the_customers_gold(auth_headers, world):
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    invoice, line = _sold(auth_headers, world)                     # 10 g of 21k at 7,000
    _holds_18k(world)
    correction, lines = _entry(_correct(auth_headers, invoice, line, [
        {'karat': 21, 'weight': 6.0, 'price': 4200.0}, {'karat': 18, 'weight': 4.0, 'price': 2800.0}]))
    assert _grams(lines, world['showroom'].id) == {21: 4.0, 18: -4.0}, 'the 21k not sold back, the 18k sold out'
    customer_gold = db.session.get(Account, world['customer'].account_id).memo_account_id
    assert _grams(lines, customer_gold) == {21: -4.0, 18: 4.0}
    assert not any(float(l.cash_debit or 0) for l in lines), 'no money'
    assert [(int(i.karat), i.weight) for i in InvoiceItem.query.filter_by(invoice_id=invoice.id).order_by(InvoiceItem.id)] \
        == [(21, 6.0), (18, 4.0)]


def test_a_price_put_right_is_owed_by_the_customer_and_earned(auth_headers, world):
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    invoice, line = _sold(auth_headers, world)
    correction, lines = _entry(_correct(auth_headers, invoice, line, [{'karat': 21, 'weight': 10.0, 'price': 7100.0}]))
    assert _cash(lines, world['customer'].account_id) == pytest.approx(100.0)
    revenue = get_account_id_for_mapping('بيع', 'sales_gold_new') or get_account_id_for_mapping('بيع', 'revenue')
    assert _cash(lines, revenue) == pytest.approx(-100.0)
    assert Invoice.query.get(invoice.id).total == pytest.approx(7100.0)
    assert correction.after['profit']['profit_cash'] == pytest.approx(correction.before['profit']['profit_cash'] + 100.0)


def test_its_vat_is_at_its_own_invoices_rate(auth_headers, world, vat_mapped):
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    invoice, line = _sold(auth_headers, world)
    line.tax, invoice.total_tax = 700.0, 700.0                  # invoiced at 10 %
    db.session.flush()
    correction, lines = _entry(_correct(auth_headers, invoice, line, [{'karat': 21, 'weight': 10.0, 'price': 7100.0}]))
    vat = get_account_id_for_mapping('بيع', 'vat_payable')
    assert _cash(lines, vat) == pytest.approx(-10.0), '10 % of the 100, not today\'s rate'
    assert _cash(lines, world['customer'].account_id) == pytest.approx(110.0)
    assert InvoiceItem.query.get(line.id).tax == pytest.approx(710.0)


def test_its_wage_is_released_with_the_weight_sold(auth_headers, world):
    from accounting.wages import manufacturing_wage_expense_account_id
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    invoice, line = _sold(auth_headers, world)
    line.wage, invoice.manufacturing_wage_mode_snapshot = 20.0, 'inventory'
    db.session.flush()
    correction, lines = _entry(_correct(auth_headers, invoice, line, [{'karat': 21, 'weight': 11.0, 'price': 7000.0}]))
    assert _cash(lines, manufacturing_wage_expense_account_id()) == pytest.approx(20.0), '1 g more at 20 a gram'


def test_a_categorised_line_in_another_karat_needs_its_category(auth_headers, world):
    from models import Category
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    invoice, line = _sold(auth_headers, world)
    ring = Category(name='خاتم 21 اختبار', karat='21', is_scrap=False, is_active=True)
    db.session.add(ring)
    db.session.flush()
    line.category_id = ring.id
    db.session.flush()
    resp = _correct(auth_headers, invoice, line, [{'karat': 18, 'weight': 10.0, 'price': 7000.0}])
    assert resp.status_code == 400 and resp.get_json()['error'] == 'correction_category_required'


def test_from_the_cost_day_its_gold_cost_moves_at_the_sales_own_cost_a_gram(auth_headers, world):
    Settings.query.first().gold_cost_from = date(2026, 1, 1)
    db.session.flush()
    _square('worked', world['showroom'], weight=100.0, value=50000.0)   # at 500
    invoice, line = _sold(auth_headers, world)                          # cost 5,000
    _holds_18k(world)
    correction, lines = _entry(_correct(auth_headers, invoice, line, [{'karat': 18, 'weight': 10.0, 'price': 7000.0}]))
    lost = 10.0 * 3 / 21 * 500.0                                        # 1.4286 g fewer sold
    assert _cash(lines, role_account_id('gold_inventory_new')) == pytest.approx(lost, abs=0.02)
    cost = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_cost_of_sales')
    assert _cash(lines, cost) == pytest.approx(-lost, abs=0.02)


def test_the_list_suggests_the_safe_the_sale_took_its_gold_from(auth_headers, world):
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    invoice, _ = _sold(auth_headers, world)
    listed = flask_app.test_client().get(f'/api/invoices/{invoice.id}/corrections', headers=auth_headers).get_json()
    assert listed['suggested_safe_box_id'] == _showroom_safe().id
