"""Gold bought for riyals enters its pool's stock at its price (ADR-042 phase 3, step 2).

The owner (21 Oct 2026): «اتفق مع توصياتك بجميع القرارات». From the day the
settings name (gold_cost_from -- 2027's first, ADR-044), a gold purchase paid in
riyals is no longer an expense on purchases (512): its price is the value of
the gold in its pool's stock (1310 the scrap, 1300 the worked), costed out
when it is sold (step 3). With no day set nothing changes: 2026 posts as ever.

  - a customer's scrap purchase: debit the scrap stock its price;
  - an office reservation settled: the same, the gold at the office's deposit;
  - a pool short (owing a supplier more gold than it holds) is covered first
    at the short's average; the difference between the price and it goes to
    «فروق تكلفة تبادل الذهب»;
  - a customer purchase's return takes its price back out of the stock;
  - the replay reads what is written as it computes it.

Run:
    python -m pytest tests/test_gold_bought_enters_its_stock.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from accounting.chart_tree import role_account_id
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
from app import app as flask_app
from models import (Account, AccountingMapping, Customer, Employee, Invoice, JournalEntry, JournalEntryLine,
                    PaymentMethod, SafeBox, Settings, db)
from services.gold_cost import pool_state, replay
from tests.test_gold_cost import _account, _child, _entry, _role_twin
from tests.test_office_reservation_is_a_purchase import _create, _settle, rworld  # noqa: F401 (fixture)

ROLE = 'gold_exchange_difference'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _from(day):
    Settings.query.first().gold_cost_from = day
    db.session.flush()


@pytest.fixture
def exchange():
    account = Account(account_number=f'529{uuid.uuid4().int % 10**5:05d}', name='فروق تكلفة تبادل الذهب',
                      type='Expense', transaction_type='cash')
    db.session.add(account)
    db.session.flush()
    row = AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=ROLE).first()
    if row is None:
        row = AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=ROLE)
        db.session.add(row)
    row.account_id, row.is_active = account.id, True
    db.session.flush()
    return account


@pytest.fixture
def world():
    """A cash method, and a holder whose custody -- a stock location, scrap's
    pool -- the scrap gold goes to, as in production."""
    box = SafeBox(name=f'خزينة GC {uuid.uuid4().hex[:6]}', safe_type='cash',
                  account_id=Account.query.get(15).id, is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(payment_type='cash', name=f'نقداً GC {uuid.uuid4().hex[:6]}', commission_rate=0.0,
                       is_active=True, default_safe_box_id=box.id)
    custody = Account(account_number=f'79{uuid.uuid4().int % 10**6:06d}', name='عهدة GC', type='Asset',
                      transaction_type='gold', tracks_weight=True)
    db.session.add_all([pm, custody])
    db.session.flush()
    gold_box = SafeBox(name=f'عهدة ذهب GC {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=custody.id,
                       stock_location='custody', is_active=True)
    db.session.add(gold_box)
    db.session.flush()
    holder = Employee.query.first()
    holder.gold_safe_box_id = gold_box.id
    db.session.flush()
    return {'pm': pm, 'customer': Customer.query.first(), 'holder': holder, 'custody': custody}


def _purchase(headers, w, *, grams=10.0, price=1500.0):
    """A customer's 21k scrap, paid in cash -- below the live price, posted at once."""
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json={
        'customer_id': w['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': w['holder'].id, 'scrap_holder_employee_id': w['holder'].id,
        'safe_box_id': w['pm'].default_safe_box_id, 'date': datetime(2026, 10, 21, 12).isoformat(),
        'total': price, 'total_weight': grams, 'total_cost': price, 'total_tax': 0.0, 'amount_paid': price,
        'payments': [{'payment_method_id': w['pm'].id, 'amount': price}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': grams, 'standing_weight': grams, 'stones_weight': 0.0,
                   'price': price, 'net': price, 'quantity': 1}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    return resp.get_json()


def _lines(reference_type, reference_id):
    db.session.expire_all()
    entries = JournalEntry.query.filter_by(reference_type=reference_type, reference_id=reference_id,
                                           is_deleted=False).all()
    return [l for e in entries for l in JournalEntryLine.query.filter_by(journal_entry_id=e.id, is_deleted=False)]


def _cash(lines, account_id):
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in lines if l.account_id == account_id), 2)


SCRAP_STOCK = lambda: role_account_id('gold_inventory_scrap')                              # noqa: E731
PURCHASES = lambda: get_account_id_for_mapping('شراء من عميل', 'purchases_gold_scrap')    # noqa: E731


def test_with_no_day_set_a_purchase_posts_as_it_always_has(auth_headers, world):
    _from(None)
    invoice = _purchase(auth_headers, world)
    lines = _lines('invoice', invoice['id'])
    assert _cash(lines, PURCHASES()) == pytest.approx(1500.0)
    assert _cash(lines, SCRAP_STOCK()) == pytest.approx(0.0)


def test_a_customers_scrap_enters_the_scrap_stock_at_its_price(auth_headers, world, exchange):
    _from(date(2026, 1, 1))
    _square_the_scrap_pool(weight=50.0, value=7500.0)           # held, at 150 a gram: no short to cover
    before = pool_state('scrap')
    invoice = _purchase(auth_headers, world)
    lines = _lines('invoice', invoice['id'])
    assert _cash(lines, SCRAP_STOCK()) == pytest.approx(1500.0)
    assert _cash(lines, PURCHASES()) == pytest.approx(0.0), 'not an expense any more'
    assert _cash(lines, exchange.id) == pytest.approx(0.0)
    after = pool_state('scrap')
    assert (after.weight - before.weight, after.value - before.value) == (pytest.approx(10.0), pytest.approx(1500.0))


def _square_the_scrap_pool(*, weight, value):
    """Bring the scrap pool to *weight* main-karat grams worth *value*, by one
    entry on a scrap safe and the scrap stock (whatever the test database holds)."""
    now = pool_state('scrap')
    safe = _child(_account('7139'), 'كسر تسوية اختبار')
    db.session.add(SafeBox(name=f'كسر GC {uuid.uuid4().hex[:4]}', safe_type='gold', account_id=safe.id,
                           stock_location='scrap', is_active=True))
    other = _child(_account('1100'), 'مقابل اختبار')
    dw, dv = weight - now.weight, value - now.value
    je = JournalEntry(entry_number=f'JE-GC-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 20, 9),
                      description='تسوية اختبار', entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    stock = db.session.get(Account, SCRAP_STOCK())
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=safe.id, description='t',
                         **({'debit_21k': dw} if dw > 0 else {'credit_21k': -dw})),
        JournalEntryLine(journal_entry_id=je.id, account_id=stock.id, description='t',
                         **({'cash_debit': dv} if dv > 0 else {'cash_credit': -dv})),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, description='t',
                         **({'cash_credit': dv} if dv > 0 else {'cash_debit': -dv})),
    ])
    db.session.flush()
    state = pool_state('scrap')
    assert (state.weight, state.value) == (pytest.approx(weight), pytest.approx(value))


def test_a_short_pool_is_covered_first_and_the_difference_said(auth_headers, world, exchange):
    _from(date(2026, 1, 1))
    _square_the_scrap_pool(weight=-4.0, value=-400.0)          # 4 g owed, at 100 a gram
    invoice = _purchase(auth_headers, world, grams=10.0, price=1500.0)   # 150 a gram
    lines = _lines('invoice', invoice['id'])
    assert _cash(lines, exchange.id) == pytest.approx(200.0), '4 g covered at 150 against 100'
    assert _cash(lines, SCRAP_STOCK()) == pytest.approx(1300.0)
    after = pool_state('scrap')
    assert (after.weight, after.value, after.average) == (pytest.approx(6.0), pytest.approx(900.0), pytest.approx(150.0))


def test_a_short_with_no_value_is_refused_saying_why(auth_headers, world, exchange):
    _from(date(2026, 1, 1))
    _square_the_scrap_pool(weight=-4.0, value=0.0)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': world['holder'].id,
        'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
        'date': datetime(2026, 10, 21, 12).isoformat(), 'total': 1500.0, 'total_weight': 10.0,
        'total_cost': 1500.0, 'total_tax': 0.0, 'amount_paid': 1500.0,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': 1500.0}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': 10.0, 'standing_weight': 10.0, 'stones_weight': 0.0,
                   'price': 1500.0, 'net': 1500.0, 'quantity': 1}]})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'gold_cost_short_without_value'


def test_the_role_unmapped_refuses_the_purchase_saying_where(auth_headers, world):
    _from(date(2026, 1, 1))
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': world['holder'].id,
        'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
        'date': datetime(2026, 10, 21, 12).isoformat(), 'total': 1500.0, 'total_weight': 10.0,
        'total_cost': 1500.0, 'total_tax': 0.0, 'amount_paid': 1500.0,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': 1500.0}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': 10.0, 'standing_weight': 10.0, 'stones_weight': 0.0,
                   'price': 1500.0, 'net': 1500.0, 'quantity': 1}]})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']
    assert Invoice.query.filter_by(total=1500.0, invoice_type='شراء من عميل').filter(
        Invoice.date >= datetime(2026, 10, 21)).count() == 0


def test_a_purchase_returned_takes_its_price_back_out_of_the_stock(auth_headers, world, exchange):
    _from(date(2026, 1, 1))
    _square_the_scrap_pool(weight=50.0, value=7500.0)
    invoice = _purchase(auth_headers, world)
    # Given back from the custody it went into: the holder named (a full reversal
    # names none, and takes it from the user's own custody).
    item = Invoice.query.get(invoice['id']).items[0]
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'مرتجع شراء', 'gold_type': 'scrap',
        'original_invoice_id': invoice['id'], 'return_reason': 'عيب',
        'scrap_holder_employee_id': world['holder'].id, 'date': datetime(2026, 10, 21, 13).isoformat(),
        'total': 1500.0, 'total_weight': 10.0, 'total_tax': 0.0, 'total_cost': 1500.0, 'amount_paid': 1500.0,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': 1500.0}],
        'items': [{'original_invoice_item_id': item.id, 'name': 'كسر', 'karat': 21, 'weight': 10.0,
                   'quantity': 1, 'cost': 1500.0, 'net': 1500.0, 'tax': 0.0, 'price': 1500.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    lines = _lines('invoice', resp.get_json()['id'])
    assert _cash(lines, SCRAP_STOCK()) == pytest.approx(-1500.0)
    assert _cash(lines, get_account_id_for_mapping('مرتجع شراء', 'purchase_returns')) == pytest.approx(0.0)
    after = pool_state('scrap')
    assert (after.weight, after.value) == (pytest.approx(50.0), pytest.approx(7500.0))


def test_an_office_reservation_enters_the_scrap_stock_at_its_price(auth_headers, rworld, exchange):
    _from(date(2026, 1, 1))
    _square_the_scrap_pool(weight=50.0, value=20000.0)
    rid = _create(auth_headers, rworld)
    resp = _settle(auth_headers, rid)
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    lines = _lines('office_reservation', rid)
    assert _cash(lines, SCRAP_STOCK()) == pytest.approx(12.5 * 400.0)
    assert _cash(lines, rworld['purchases'].id) == pytest.approx(0.0)
    after = pool_state('scrap')
    assert (after.weight, after.value) == (pytest.approx(62.5), pytest.approx(25000.0))


def test_the_replay_reads_a_covered_short_and_a_return_as_they_are_written(exchange):
    """In 2032, alone: 30 g bought at 410; 100 g of worked gold received for gold
    (70 g short at 410); 100 g bought at 450 -- 70 cover the short, 2,800 to
    the difference; 10 g returned at 4,500; 10 g sold at the average. The
    ledger and the replay agree."""
    from accounting.chart_tree import role_account_id as rid_of
    b = {
        'showroom': _child(_account('7139'), 'معروض 2032'), 'scrap': _child(_account('7139'), 'كسر 2032'),
        'supplier': _child(_role_twin('worked_gold_suppliers_root'), 'مورد 2032 وزني'),
        'twin': _child(_account('7512'), 'مشتريات وزني 2032'), 'cash': _child(_account('1100'), 'صندوق 2032'),
        'customer': _child(_role_twin('customer_receivables_root'), 'عميل 2032 وزني'),
        'cost_of_sales': _child(_account('521'), 'تكلفة مبيعات 2032'),
    }
    for key, location in (('showroom', 'showroom'), ('scrap', 'scrap')):
        db.session.add(SafeBox(name=f'{key} 2032 {uuid.uuid4().hex[:4]}', safe_type='gold',
                               account_id=b[key].id, stock_location=location, is_active=True))
    db.session.flush()
    worked_value, scrap_value = (db.session.get(Account, rid_of('gold_inventory_new')),
                                 db.session.get(Account, rid_of('gold_inventory_scrap')))
    _entry(1, [(b['scrap'], {'debit_21k': 30}), (b['twin'], {'credit_21k': 30}),
               (scrap_value, {'cash_debit': 12300}), (b['cash'], {'cash_credit': 12300})])
    _entry(2, [(b['showroom'], {'debit_21k': 100}), (b['supplier'], {'credit_21k': 100}),
               (worked_value, {'cash_debit': 41000}), (scrap_value, {'cash_credit': 41000})])
    _entry(3, [(b['scrap'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (scrap_value, {'cash_debit': 42200}), (exchange, {'cash_debit': 2800}),
               (b['cash'], {'cash_credit': 45000})])
    _entry(4, [(b['scrap'], {'credit_21k': 10}), (b['twin'], {'debit_21k': 10}),
               (scrap_value, {'cash_credit': 4500}), (b['cash'], {'cash_debit': 4500})])
    # a sale credits the stock too -- its cost, against a cost of sales: still a sale
    _entry(5, [(b['scrap'], {'credit_21k': 10}), (b['customer'], {'debit_21k': 10}),
               (b['cost_of_sales'], {'cash_debit': 4500}), (scrap_value, {'cash_credit': 4500})])

    r = replay(opening_price=0.0, since=date(2032, 1, 1), until=date(2032, 2, 1))
    assert r.others == []
    assert r.months['2032-01'].exchange_difference == pytest.approx(2800)
    assert r.months['2032-01'].sold_scrap_g == pytest.approx(10), 'the sale is a sale, not a purchase undone'
    jan, feb = datetime(2032, 1, 1), datetime(2032, 2, 1)
    for name in ('worked', 'scrap'):
        a, z = pool_state(name, until=jan), pool_state(name, until=feb)
        assert z.weight - a.weight == pytest.approx(r.pools[name].weight), name
        assert z.value - a.value == pytest.approx(r.pools[name].value), name
    assert (r.pools['scrap'].weight, r.pools['scrap'].value) == (pytest.approx(10), pytest.approx(4500))
