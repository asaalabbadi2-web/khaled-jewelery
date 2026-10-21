"""Gold sold leaves its pool's stock at the pool's average (ADR-042 phase 3, step 3).

The owner (21 Oct 2026): «اتفق مع توصياتك بجميع القرارات». From the day the
settings name (gold_cost_from), a sale writes the cost of its gold: debit its
cost of sales, credit its pool's stock, at the pool's average when it is sold.
Two margins, seen apart: the worked on «تكلفة مبيعات الذهب», the scrap on
«تكلفة الكسر المباع». With no day set, a sale posts as it always has -- no cost.

A sale returned brings back its sale's posted cost, in the share returned --
the cost the sale wrote, not today's average nor the screen's figure. A return
of a sale that wrote none (before the day) is refused by name. A pool with no
average sells nothing: refused, saying so. The below-cost check reads the same
average. The replay reads what is written as it computes it.

Run:
    python -m pytest tests/test_gold_sold_at_its_cost.py -v
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

SCRAP_ROLE = 'scrap_cost_of_sales'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _from(day):
    Settings.query.first().gold_cost_from = day
    db.session.flush()


def _map(role, number):
    account = Account(account_number=f'{number}{uuid.uuid4().int % 10**5:05d}', name=role, type='Expense',
                      transaction_type='cash')
    db.session.add(account)
    db.session.flush()
    row = AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=role).first()
    if row is None:
        row = AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=role)
        db.session.add(row)
    row.account_id, row.is_active = account.id, True
    db.session.flush()
    return account


def _located_safe(account, location):
    safe = SafeBox.query.filter_by(account_id=account.id).first()
    if safe is None:
        safe = SafeBox(name=f'{location} GS {uuid.uuid4().hex[:4]}', safe_type='gold', account_id=account.id,
                       is_active=True)
        db.session.add(safe)
    safe.stock_location = location
    db.session.flush()
    return safe


@pytest.fixture
def world():
    """As in production: the display stock keeps its weight on its memo twin,
    the showroom safe; the main scrap safe is a scrap location; a cash method
    and a customer."""
    stock = db.session.get(Account, role_account_id('gold_inventory_new'))
    if not stock.memo_account_id:
        memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}', name='المعروض وزني GS',
                       type='Asset', transaction_type='gold', tracks_weight=True)
        db.session.add(memo)
        db.session.flush()
        stock.memo_account_id = memo.id
    showroom = db.session.get(Account, stock.memo_account_id)
    _located_safe(showroom, 'showroom')
    scrap_account = Account(account_number=f'7131{uuid.uuid4().int % 10**5:05d}', name='كسر GS', type='Asset',
                            transaction_type='gold', tracks_weight=True)
    db.session.add(scrap_account)
    db.session.flush()
    scrap_safe = _located_safe(scrap_account, 'scrap')
    Settings.query.first().main_scrap_gold_safe_box_id = scrap_safe.id
    box = SafeBox(name=f'خزينة GS {uuid.uuid4().hex[:6]}', safe_type='cash', account_id=Account.query.get(15).id,
                  is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(payment_type='cash', name=f'نقداً GS {uuid.uuid4().hex[:6]}', commission_rate=0.0,
                       is_active=True, default_safe_box_id=box.id)
    db.session.add(pm)
    db.session.flush()
    return {'customer': Customer.query.first(), 'holder': Employee.query.first(), 'pm': pm,
            'showroom': showroom, 'scrap': scrap_account,
            'cost_scrap': _map(SCRAP_ROLE, '522')}


def _square(name, account, *, weight, value):
    """Bring *name*'s pool to *weight* main-karat grams worth *value*, by one
    entry on *account* (a safe of the pool) and the pool's stock."""
    now = pool_state(name)
    stock = db.session.get(Account, role_account_id('gold_inventory_new' if name == 'worked' else 'gold_inventory_scrap'))
    other = _child(_account('1100'), 'مقابل GS')
    dw, dv = weight - now.weight, value - now.value
    je = JournalEntry(entry_number=f'JE-GS-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 20, 9),
                      description='تسوية اختبار', entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='t',
                         **({'debit_21k': dw} if dw > 0 else {'credit_21k': -dw})),
        JournalEntryLine(journal_entry_id=je.id, account_id=stock.id, description='t',
                         **({'cash_debit': dv} if dv > 0 else {'cash_credit': -dv})),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, description='t',
                         **({'cash_credit': dv} if dv > 0 else {'cash_debit': -dv})),
    ])
    db.session.flush()
    state = pool_state(name)
    assert (state.weight, state.value) == (pytest.approx(weight), pytest.approx(value))


def _sale(headers, w, *, grams=10.0, price=7000.0, gold_type='new', day=21):
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json={
        'customer_id': w['customer'].id, 'invoice_type': 'بيع', 'gold_type': gold_type,
        'employee_id': w['holder'].id, 'date': datetime(2026, 10, day, 12).isoformat(),
        'total': price, 'total_weight': grams, 'total_tax': 0.0, 'total_cost': 1.0, 'amount_paid': 0.0,
        'payments': [],
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': grams, 'price': price, 'net': price, 'quantity': 1,
                   'wage': 0, 'selling_price': price}]})
    return resp


def _lines(invoice_id):
    db.session.expire_all()
    entries = JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id, is_deleted=False).all()
    return [l for e in entries for l in JournalEntryLine.query.filter_by(journal_entry_id=e.id, is_deleted=False)]


def _cash(lines, account_id):
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in lines if l.account_id == account_id), 2)


WORKED_STOCK = lambda: role_account_id('gold_inventory_new')                                # noqa: E731
SCRAP_STOCK = lambda: role_account_id('gold_inventory_scrap')                               # noqa: E731
WORKED_COST = lambda: get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_cost_of_sales')  # noqa: E731


def test_with_no_day_set_a_sale_writes_no_cost(auth_headers, world):
    _from(None)
    resp = _sale(auth_headers, world)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    lines = _lines(resp.get_json()['id'])
    assert _cash(lines, WORKED_COST()) == pytest.approx(0.0)
    assert _cash(lines, WORKED_STOCK()) == pytest.approx(0.0)


def test_a_sale_costs_its_gold_at_the_worked_average(auth_headers, world):
    _from(date(2026, 1, 1))
    _square('worked', world['showroom'], weight=100.0, value=50000.0)       # at 500 a gram
    resp = _sale(auth_headers, world)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    lines = _lines(resp.get_json()['id'])
    assert _cash(lines, WORKED_COST()) == pytest.approx(5000.0)
    assert _cash(lines, WORKED_STOCK()) == pytest.approx(-5000.0)
    assert float(Invoice.query.get(resp.get_json()['id']).total_cost) == pytest.approx(5000.0), 'not the screen\'s 1.0'
    after = pool_state('worked')
    assert (after.weight, after.value, after.average) == (pytest.approx(90.0), pytest.approx(45000.0),
                                                          pytest.approx(500.0))


def test_a_scrap_sale_costs_at_the_scrap_average_on_its_own_margin(auth_headers, world):
    _from(date(2026, 1, 1))
    _square('scrap', world['scrap'], weight=40.0, value=16000.0)            # at 400 a gram
    resp = _sale(auth_headers, world, gold_type='scrap', price=5000.0)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    lines = _lines(resp.get_json()['id'])
    assert _cash(lines, world['cost_scrap'].id) == pytest.approx(4000.0)
    assert _cash(lines, SCRAP_STOCK()) == pytest.approx(-4000.0)
    assert _cash(lines, WORKED_COST()) == pytest.approx(0.0), 'two margins, apart'


def test_a_sale_returned_brings_back_its_sales_cost_not_todays_average(auth_headers, world):
    _from(date(2026, 1, 1))
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    sold = _sale(auth_headers, world).get_json()
    _square('worked', world['showroom'], weight=90.0, value=54000.0)        # the average moves to 600
    resp = flask_app.test_client().post(f'/api/invoices/{sold["id"]}/reverse', headers=auth_headers,
                                        json={'reason': 'عيب', 'payments': []})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    lines = _lines(resp.get_json()['id'])
    assert _cash(lines, WORKED_STOCK()) == pytest.approx(5000.0), 'at its sale\'s cost (500), not 600'
    assert _cash(lines, WORKED_COST()) == pytest.approx(-5000.0)
    after = pool_state('worked')
    assert (after.weight, after.value) == (pytest.approx(100.0), pytest.approx(59000.0))


def test_a_return_of_a_sale_that_wrote_no_cost_is_refused_by_name(auth_headers, world):
    _from(None)
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    sold = _sale(auth_headers, world).get_json()
    _from(date(2026, 1, 1))
    resp = flask_app.test_client().post(f'/api/invoices/{sold["id"]}/reverse', headers=auth_headers,
                                        json={'reason': 'عيب', 'payments': []})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'gold_cost_return_of_uncosted_sale'


def test_a_pool_with_no_average_sells_nothing(auth_headers, world):
    _from(date(2026, 1, 1))
    _square('worked', world['showroom'], weight=100.0, value=0.0)
    resp = _sale(auth_headers, world)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'gold_cost_no_average'


def test_the_scrap_cost_role_unmapped_refuses_a_scrap_sale_saying_where(auth_headers, world):
    _from(date(2026, 1, 1))
    _square('scrap', world['scrap'], weight=40.0, value=16000.0)
    AccountingMapping.query.filter_by(account_type=SCRAP_ROLE).delete()
    resp = _sale(auth_headers, world, gold_type='scrap', price=5000.0)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']


def test_below_cost_reads_the_pools_average(auth_headers, world):
    _from(date(2026, 1, 1))
    _square('worked', world['showroom'], weight=100.0, value=50000.0)
    resp = _sale(auth_headers, world, price=4000.0)                       # 10 g at 500 cost 5,000
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    assert 'below_cost' in (resp.get_json().get('approval_reasons') or [])


def test_the_replay_reads_a_sale_and_its_return_as_they_are_written():
    """In 2032, alone: 100 g of worked gold bought at 500; 10 g sold at the
    average (5,000); the sale returned at its cost, 5,000. The ledger and the
    replay agree, and nothing is left sold."""
    b = {'showroom': _child(_account('7139'), 'معروض 2032 GS'),
         'customer': _child(_role_twin('customer_receivables_root'), 'عميل 2032 GS وزني'),
         'twin': _child(_account('7512'), 'مشتريات وزني 2032 GS'), 'cash': _child(_account('1100'), 'صندوق 2032 GS'),
         'equity': _child(_account('1100'), 'مقابل 2032 GS')}
    db.session.add(SafeBox(name=f'معروض 2032 {uuid.uuid4().hex[:4]}', safe_type='gold', account_id=b['showroom'].id,
                           stock_location='showroom', is_active=True))
    db.session.flush()
    worked_value = db.session.get(Account, role_account_id('gold_inventory_new'))
    cost = db.session.get(Account, WORKED_COST())
    _entry(1, [(b['showroom'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (worked_value, {'cash_debit': 50000}), (b['cash'], {'cash_credit': 50000})])
    _entry(2, [(b['showroom'], {'credit_21k': 10}), (b['customer'], {'debit_21k': 10}),
               (cost, {'cash_debit': 5000}), (worked_value, {'cash_credit': 5000})])
    _entry(3, [(b['showroom'], {'debit_21k': 10}), (b['customer'], {'credit_21k': 10}),
               (worked_value, {'cash_debit': 5000}), (cost, {'cash_credit': 5000})])

    r = replay(opening_price=0.0, since=date(2032, 1, 1), until=date(2032, 2, 1))
    assert r.others == []
    month = r.months['2032-01']
    assert (month.sold_worked_g, month.cost_of_worked_sold) == (pytest.approx(0), pytest.approx(0)), \
        'sold and returned: nothing sold'
    jan, feb = datetime(2032, 1, 1), datetime(2032, 2, 1)
    a, z = pool_state('worked', until=jan), pool_state('worked', until=feb)
    assert z.weight - a.weight == pytest.approx(r.pools['worked'].weight)
    assert z.value - a.value == pytest.approx(r.pools['worked'].value)


def test_the_income_statement_says_its_basis_from_the_settings_day():
    from services.gold_cost_books import cost_basis
    _from(date(2032, 3, 1))
    assert cost_basis(datetime(2032, 1, 1), datetime(2032, 3, 1))[0] == 'purchases', 'the past as it was posted'
    assert cost_basis(datetime(2032, 3, 1), datetime(2032, 4, 1))[0] == 'moving_average'
    basis, note = cost_basis(datetime(2032, 2, 1), datetime(2032, 4, 1))
    assert basis == 'mixed' and '2032-03-01' in note
