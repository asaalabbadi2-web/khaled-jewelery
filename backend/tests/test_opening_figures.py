"""A new year's opening figures beside the closing books (ADR-044, TR-2).

The owner, 6 Nov 2026: «شاشة افتتاح في النظام» -- a row for each asset or
liability account holding a balance, its weight twin in its row; what the
count gives is no row (a counted stock safe). The figure is empty until
entered («فارغة حتى تُؤكَّد») with its source, at two places; a party's cash
says whether it opens as gold at the closing price or stays cash waiting to be
closed («الاثنين معا»). The figures less the books are what equity takes. The
manager enters, the owner approves («المدير يُدخل، والمالك يعتمد»): approved
only once every row has its figure, then nothing changes.

TR-3: a supplier's cash stays cash -- its wages closed when recorded (the
owner, 7 Nov 2026: «اذا ضل له اجور فتبقى نقديه ولا تسكر ذهب»); a customer's
or an office's asks gold or waiting. The approval freezes the count day's
closing price (the office's last on 31 Dec, ADR-063) and the riyals waiting
then (ADR-048); a party opening as gold takes its riyals at that price. 2027's
queue starts with 2026's waiting riyals at the count price (decision 1:
«تنتقل منتظرة بسعر الجرد»).

Run:
    python -m pytest tests/test_opening_figures.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from auth_decorators import generate_token
from models import Account, AppUser, Customer, GoldPrice, JournalEntry, JournalEntryLine, OpeningApproval, \
    OpeningFigure, Supplier, db
from tests.test_stock_count import roles  # noqa: F401 -- the count's two roles, fenced
from tests.test_stock_screens import _safe, _stock

NOW = datetime(2026, 12, 31, 20, 0)
COUNT_DAY_CLOSE = datetime(2026, 12, 31, 23, 50)     # the day's last price
YEAR = 2027


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _post(lines):
    je = JournalEntry(entry_number=f'JE-OP-{uuid.uuid4().hex[:8]}', date=NOW, description='رصيد', entry_type='عادي',
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='رصيد', **cols))
    db.session.flush()


def _seat(account, root_id):
    """The party's group under its root, as on production (the test chart
    seeds the party groups without a parent); fenced, undone after the test."""
    top = account
    while top.parent_id:
        top = db.session.get(Account, top.parent_id)
    if top.id != root_id:
        root = db.session.get(Account, root_id)
        top.parent_id = root.id
        twin, root_twin = db.session.get(Account, top.memo_account_id or -1), db.session.get(Account, root.memo_account_id or -1)
        if twin is not None and root_twin is not None and twin.parent_id is None:
            twin.parent_id = root_twin.id
    db.session.flush()


@pytest.fixture
def books():
    """A cash account with 4,137.00; a supplier owed 1,500.00 and 290.30 g of
    24k on his twin; a customer owing 800.00, and 250.00 on the customers'
    group itself; a counted showroom safe with 10 g; the office's price on the
    count day."""
    from accounting.chart_tree import role_account_id
    from party_account_service import ensure_customer_accounts, ensure_supplier_accounts
    cash = Account(account_number=f'1100{uuid.uuid4().int % 10**4:04d}', name='حساب بنكي مؤقت OP', type='Asset',
                   transaction_type='cash', parent_id=role_account_id('cash_root'))
    db.session.add(cash)
    supplier = Supplier(supplier_code=f'SUP-{uuid.uuid4().hex[:6]}', name=f'مورد افتتاح {uuid.uuid4().hex[:4]}')
    db.session.add(supplier)
    db.session.flush()
    ensure_supplier_accounts(supplier)
    db.session.flush()
    own = db.session.get(Account, supplier.account_id)
    _seat(own, role_account_id('liabilities_root'))
    control = db.session.get(Account, own.parent_id)     # 2100: the suppliers' control account
    twin = db.session.get(Account, own.memo_account_id)
    other = Account(account_number=f'3{uuid.uuid4().int % 10**6:06d}', name='مقابل OP', type='Equity')
    db.session.add(other)
    db.session.flush()
    _post([(cash, {'cash_debit': 4137.0}), (own, {'cash_credit': 1500.0}), (other, {'cash_debit': -2637.0})])
    _post([(twin, {'credit_24k': 290.3}), (other, {'debit_24k': 290.3})])
    _post([(control, {'cash_credit': 600.0}), (other, {'cash_debit': 600.0})])   # owed twice, as 2100 on production
    customer = Customer(customer_code=f'C-{uuid.uuid4().hex[:6]}', name=f'عميل افتتاح {uuid.uuid4().hex[:4]}')
    db.session.add(customer)
    db.session.flush()
    ensure_customer_accounts(customer)
    db.session.flush()
    owing = db.session.get(Account, customer.account_id)
    _seat(owing, role_account_id('assets_root'))
    _post([(owing, {'cash_debit': 800.0}), (other, {'cash_credit': 800.0})])
    group = db.session.get(Account, owing.parent_id)
    _post([(group, {'cash_debit': 250.0}), (other, {'cash_credit': 250.0})])
    showroom = _safe('showroom')
    _stock(showroom, 10.0)
    db.session.add(GoldPrice(price=4000.0, date=COUNT_DAY_CLOSE))
    db.session.flush()
    return {'cash': cash, 'supplier': own, 'twin': twin, 'group': group, 'customer': owing, 'showroom': showroom,
            'control': control}


def _rows():
    from services.opening_figures import opening
    state = opening(YEAR)
    return state, {r['account_id']: r for r in state['rows']}


def test_a_row_for_each_account_holding_a_balance_its_twin_in_its_row(books):
    state, rows = _rows()
    cash = rows[books['cash'].id]
    assert cash['books']['cash'] == 4137.0 and cash['actual'] is None, 'empty until entered'
    supplier = rows[books['supplier'].id]
    assert (supplier['books']['cash'], supplier['books']['24']) == (-1500.0, -290.3)
    assert books['twin'].id not in rows, 'the twin is in its row'
    assert supplier['party'] is False, "a supplier's cash stays cash: not asked gold or waiting"
    assert rows[books['customer'].id]['party'] is True
    assert books['showroom'].account_id not in rows, 'the count gives it'
    assert rows[books['group'].id]['party'] is False, 'a group holding lines is a row, not a party (2100 on the copy)'
    assert books['control'].id not in rows, "the suppliers' control account: the close clears it to 33 (TR-4b)"
    assert state['entered'] < state['total']


def test_a_figure_has_its_source_two_places_and_a_party_s_cash_its_treatment(books):
    from services.opening_figures import OpeningRefused, enter
    with pytest.raises(OpeningRefused, match='مصدر'):
        enter(YEAR, books['cash'].id, cash=4137, karats={}, source=None, treatment=None, note=None, by='m', now=NOW)
    with pytest.raises(OpeningRefused, match='خانتين'):
        enter(YEAR, books['cash'].id, cash=4137.005, karats={}, source='statement', treatment=None, note=None,
              by='m', now=NOW)
    with pytest.raises(OpeningRefused, match='التسكير'):
        enter(YEAR, books['customer'].id, cash=800, karats={}, source='acknowledgment',
              treatment=None, note=None, by='m', now=NOW)
    enter(YEAR, books['cash'].id, cash=4100, karats={}, source='statement', treatment=None, note='كشف البنك',
          by='m', now=NOW)
    enter(YEAR, books['supplier'].id, cash=-1500, karats={'24': -290.3}, source='reconciliation',
          treatment='gold', note=None, by='m', now=NOW)
    enter(YEAR, books['customer'].id, cash=800, karats={}, source='acknowledgment', treatment='gold', note=None,
          by='m', now=NOW)
    state, rows = _rows()
    assert rows[books['cash'].id]['difference']['cash'] == -37.0
    assert rows[books['supplier'].id]['treatment'] is None, "a supplier's wages stay cash"
    assert rows[books['customer'].id]['treatment'] == 'gold'
    assert state['difference']['cash'] == pytest.approx(-37.0), 'what equity takes'


def test_approved_only_once_every_row_has_its_figure_then_nothing_changes(books):
    from services.opening_figures import OpeningRefused, approve, enter
    with pytest.raises(OpeningRefused, match='بلا رقم فعلي'):
        approve(YEAR, by='owner', now=NOW)
    _, rows = _rows()
    for row in rows.values():
        b = row['books']
        enter(YEAR, row['account_id'], cash=round(b['cash'], 2), karats={k: round(b[k], 2) for k in ('18', '21', '22', '24')},
              source='reconciliation', treatment='waiting' if row['party'] else None, note=None, by='m', now=NOW)
    approve(YEAR, by='owner', now=NOW)
    with pytest.raises(OpeningRefused, match='معتمد'):
        enter(YEAR, books['cash'].id, cash=1, karats={}, source='count', treatment=None, note=None, by='m', now=NOW)


def test_the_manager_enters_the_owner_approves(books):
    user = AppUser(username=f'manager-{uuid.uuid4().hex[:6]}', role='manager', is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    headers = {'Authorization': f'Bearer {generate_token(user)}'}
    client = flask_app.test_client()
    assert client.get(f'/api/opening/{YEAR}', headers=headers).status_code == 200
    resp = client.put(f'/api/opening/{YEAR}/{books["cash"].id}', headers=headers,
                      json={'cash': 4137, 'source': 'statement'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert client.post(f'/api/opening/{YEAR}/approve', headers=headers).status_code == 403


def _enter_all(customer_treatment='gold'):
    from services.opening_figures import enter
    _, rows = _rows()
    for row in rows.values():
        b = row['books']
        enter(YEAR, row['account_id'], cash=round(b['cash'], 2),
              karats={k: round(b[k], 2) for k in ('18', '21', '22', '24')}, source='reconciliation',
              treatment=customer_treatment if row['party'] else None, note=None, by='m', now=NOW)


def test_the_approval_freezes_the_count_day_price_and_the_waiting_riyals(books):
    """Decision 9: the closing price of the count day -- the office's last on
    31 Dec -- frozen once, with the riyals waiting then."""
    from services.opening_figures import approve
    from services.weight_position import _replayed, office_prices
    _enter_all('waiting')
    approve(YEAR, by='owner', now=NOW)
    count_day = COUNT_DAY_CLOSE.date()
    price = office_prices(count_day)(count_day)[0]
    waiting = sum(lot.cash_open for lot in _replayed(count_day).open_lots)
    approval = db.session.get(OpeningApproval, YEAR)
    assert price > 0 and approval.closing_price == pytest.approx(round(price, 4))
    assert approval.count_day == count_day
    assert approval.waiting_cash == pytest.approx(round(waiting, 2))
    assert approval.to_gold_cash == 0.0
    state, _ = _rows()
    assert state['approved']['carried_cash'] == max(round(approval.waiting_cash, 2), 0.0)


def test_a_customer_opening_as_gold_is_refused_until_its_entry_is_built(books):
    """The owner, 7 Nov 2026: «يُؤجَّل» -- turning a customer's riyals into
    gold at the close needs an entry the system has none like; no customer
    held cash on 5 Nov. Built if one does at the count; until then refused,
    said, not written."""
    from services.opening_figures import OpeningRefused, approve
    _enter_all('gold')
    with pytest.raises(OpeningRefused, match='لم يُبنَ'):
        approve(YEAR, by='owner', now=NOW)
    assert db.session.get(OpeningApproval, YEAR) is None


def test_the_approval_writes_2026_s_differences_onto_the_count_s_accounts(books, roles):
    """The owner, 7 Nov 2026: the differences in 2026 at the close («في 2026
    عند الإقفال»), onto the count's accounts («حسابا الجرد»): what is found
    short to 5220, over to 450, in riyals and in grams -- so 2026 closes on
    the figures, and 2027 opens on its closing (ADR-044's law)."""
    from datetime import time
    from models import JournalEntry, JournalEntryLine
    from services.inventory_accounting_service import InventoryAccountingService as IAS
    from services.opening_figures import approve, count_day, enter
    from accounting.mappings import get_account_id_for_mapping
    _enter_all('waiting')
    enter(YEAR, books['cash'].id, cash=4100, karats={}, source='statement', treatment=None, note='كشف البنك',
          by='m', now=NOW)
    enter(YEAR, books['supplier'].id, cash=-1500, karats={'24': -290.0}, source='reconciliation', treatment=None,
          note='كشف المورد', by='m', now=NOW)
    approve(YEAR, by='owner', now=NOW)
    approval = db.session.get(OpeningApproval, YEAR)
    entry = db.session.get(JournalEntry, approval.reconciliation_entry_id)
    assert entry.date == datetime.combine(count_day(YEAR), time(23, 59)) and entry.is_posted
    lines = JournalEntryLine.query.filter_by(journal_entry_id=entry.id).all()
    shortage = get_account_id_for_mapping('افتراضي', 'inventory_count_shortage')
    surplus_w = IAS._weight_account('inventory_count_surplus')

    def net(account_id, col):
        debit, credit = ('cash_debit', 'cash_credit') if col == 'cash' else (f'debit_{col}', f'credit_{col}')
        return round(sum(float(getattr(l, debit) or 0) - float(getattr(l, credit) or 0)
                         for l in lines if l.account_id == account_id), 3)
    assert net(books['cash'].id, 'cash') == -37.0, 'the bank short 37'
    assert net(shortage, 'cash') == 37.0, 'onto the loss'
    assert net(books['twin'].id, '24k') == 0.3, 'the supplier owes 0.3 g less'
    assert net(surplus_w, '24k') == -0.3, 'onto the surplus'
    for debit, credit in (('cash_debit', 'cash_credit'), *((f'debit_{k}k', f'credit_{k}k') for k in (18, 21, 22, 24))):
        assert round(sum(float(getattr(l, debit) or 0) - float(getattr(l, credit) or 0) for l in lines), 6) == 0, \
            f'balanced in {debit}'
    state, rows = _rows()
    assert state['approved']['reconciliation_entry'] == entry.entry_number
    assert rows[books['cash'].id]['books']['cash'] == 4100.0, '2026 closes on the figure'
    assert state['difference'] == {'cash': 0.0, 'grams': 0.0}


def test_nothing_differs_nothing_is_written(books):
    from services.opening_figures import approve
    _enter_all('waiting')
    approve(YEAR, by='owner', now=NOW)
    assert db.session.get(OpeningApproval, YEAR).reconciliation_entry_id is None


def test_2027_s_queue_starts_with_2026_s_waiting_riyals_at_the_count_price(app, db_fence):
    """Decision 1: «تنتقل منتظرة بسعر الجرد» -- one lot on the year's first
    moment, its riyals what waited less what opened as gold, at the count
    price: nothing expected of it at that price; only the year's start reads it."""
    from datetime import date
    from services.weight_position import collect_events, unrealized_parts
    db.session.add(OpeningApproval(year=2041, approved_by='owner', approved_at=datetime(2041, 1, 1),
                                   count_day=date(2040, 12, 31), closing_price=400.0, waiting_cash=10000.0,
                                   to_gold_cash=2000.0))
    db.session.flush()
    events = collect_events(datetime(2041, 1, 1), datetime(2041, 12, 31, 23, 59))
    lot = events.openings[0]
    assert (lot.when, lot.cash, lot.grams, lot.price_at_sale) == (datetime(2041, 1, 1), 8000.0, 20.0, 400.0)
    assert 'المنتظرة' in lot.ref
    assert unrealized_parts([lot], 400.0) == (pytest.approx(0.0), pytest.approx(0.0))
    later = collect_events(datetime(2041, 3, 1), datetime(2041, 12, 31, 23, 59))
    assert not any('المنتظرة' in o.ref for o in later.openings)


def test_more_turned_to_gold_than_waits_starts_the_year_with_nothing_waiting(app, db_fence):
    """A credit sale's riyals may have closed from the cash in hand while
    the customer still owes them: turning his debt to gold closes past the
    queue -- unmatched (ADR-048), not a refusal."""
    from datetime import date
    from services.weight_position import collect_events
    db.session.add(OpeningApproval(year=2043, approved_by='owner', approved_at=datetime(2043, 1, 1),
                                   count_day=date(2042, 12, 31), closing_price=400.0, waiting_cash=500.0,
                                   to_gold_cash=800.0))
    db.session.flush()
    events = collect_events(datetime(2043, 1, 1), datetime(2043, 12, 31, 23, 59))
    assert not any('المنتظرة' in o.ref for o in events.openings)


def test_the_transition_refuses_an_opening_not_approved(app, db_fence):
    from services.transition_2027 import TransitionRefused, carry_waiting
    with pytest.raises(TransitionRefused, match='لم يُعتمد'):
        carry_waiting(db.engine, year=2042)


def test_the_close_values_the_stock_at_the_count_day_s_market_price_and_clears_2100_to_33(books, roles):
    """The owner, 6 Nov 2026 (decision 2): the gold at the market price of 31
    Dec, without the office's fees or discount; 7 Nov: the difference to
    «فروقات تقييم الذهب» (33), and with it 2100's own balance (owed twice) and
    the riyals on a pool's weight account («إلى 33 مع التقييم») -- ADR-042's
    entry, its pools at that price. Written after the differences, on the
    count day's last minute."""
    from datetime import time
    from accounting.mappings import get_account_id_for_mapping
    from models import JournalEntry
    from pricing.gold_price_service import get_main_karat
    from pricing.office_price import gram_price
    from services.gold_cost import pool_state
    from services.live_balances import live_balances_by_account_ids
    from services.opening_figures import approve, count_day
    _enter_all('waiting')
    approve(YEAR, by='owner', now=NOW)
    approval = db.session.get(OpeningApproval, YEAR)
    market = gram_price(4000.0, int(get_main_karat()), None)
    assert approval.market_price == pytest.approx(round(market, 4))
    entry = db.session.get(JournalEntry, approval.revaluation_entry_id)
    assert entry.date == datetime.combine(count_day(YEAR), time(23, 59)) and entry.is_posted
    for pool in ('worked', 'scrap'):
        state = pool_state(pool)
        assert state.value == pytest.approx(round(state.weight * approval.market_price, 2), abs=0.02), pool
    assert live_balances_by_account_ids({books['control'].id})[books['control'].id]['cash'] == pytest.approx(0.0)
    assert sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in entry.lines) == pytest.approx(0.0)
    valuation = get_account_id_for_mapping('افتراضي', 'valuation_equity')
    assert any(l.account_id == valuation for l in entry.lines), 'the rest to 33'
    state, _ = _rows()
    assert state['approved']['revaluation_entry'] == entry.entry_number
