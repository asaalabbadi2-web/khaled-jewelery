"""Two pools at their moving average, replayed from the books (ADR-042, phase 1).

The worked example the owner was shown (11 Oct 2026), number for number:
100 g of scrap bought at 400, 50 g from an office at 430 (average 410); 120 g
of worked gold received from a supplier for gold (into the worked pool at 410);
the supplier paid with 120 g of scrap (nothing moves); 80 g sold (cost 32,800);
60 g bought at 450 (average 436.67). And the short: 100 g received with 30 g of
scrap -- 70 g short at 410 -- covered by 100 g bought at 450: 2,800 to «فروق
تكلفة تبادل الذهب», the pool at 30 g and 450.

Run:
    python -m pytest tests/test_gold_cost.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from services.gold_cost import Pool, replay


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


# ── the pool's arithmetic ─────────────────────────────────────────────────

def test_the_worked_example_in_the_pools():
    scrap, worked = Pool(), Pool()
    scrap.put(100, 40000)
    scrap.put(50, 21500)
    assert scrap.avg == pytest.approx(410)
    worked.put(120, scrap.take(120))                       # the supplier's gold for gold
    assert (scrap.weight, worked.avg) == (pytest.approx(30), pytest.approx(410))
    assert worked.take(80) == pytest.approx(32800)         # the cost of what was sold
    scrap.put(60, 27000)
    assert scrap.avg == pytest.approx(436.67, abs=0.01)


def test_a_short_pool_is_covered_first_and_the_difference_said():
    scrap, worked = Pool(), Pool()
    scrap.put(30, 12300)
    worked.put(100, scrap.take(100))                       # 70 g short at 410
    assert scrap.weight == pytest.approx(-70) and scrap.avg == pytest.approx(410)
    difference = scrap.put(100, 45000)                     # 70 cover the short at 450
    assert difference == pytest.approx(2800)
    assert (scrap.weight, scrap.value, scrap.avg) == (pytest.approx(30), pytest.approx(13500), pytest.approx(450))


# ── the replay, from entries ──────────────────────────────────────────────

def _account(number, parent=None):
    found = Account.query.filter_by(account_number=number).first()
    if found:
        return found
    a = Account(account_number=number, name=f'ح {number}', type='Asset', parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _child(root, tag):
    a = Account(account_number=f'{root.account_number}9{uuid.uuid4().int % 10**5}', name=tag, type='Asset',
                parent_id=root.id)
    db.session.add(a)
    db.session.flush()
    return a


def _entry(day, lines, reference_type=None):
    je = JournalEntry(entry_number=f'JE-G-{uuid.uuid4().hex[:8]}', date=datetime(2032, 1, day, 10),
                      description='اختبار', entry_type='عادي', reference_type=reference_type,
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='اختبار', **cols))
    db.session.flush()


@pytest.fixture
def books():
    return {
        'display': _child(_account('71300'), 'معروض اختبار'),
        'scrap_safe': _child(_account('71310'), 'صندوق كسر اختبار'),
        'supplier': _child(_account('7210'), 'مورد اختبار وزني'),
        'customer': _child(_account('7120'), 'عميل اختبار وزني'),
        'twin': _child(_account('7512'), 'مشتريات وزني اختبار'),
        'purchases': _child(_account('512'), 'مشتريات اختبار'),
        'cash': _child(_account('1100'), 'صندوق اختبار'),
    }


def test_the_replay_reads_the_example_from_the_books(books):
    b = books
    _entry(1, [(b['scrap_safe'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (b['purchases'], {'cash_debit': 40000}), (b['cash'], {'cash_credit': 40000})])          # bought
    _entry(2, [(b['scrap_safe'], {'debit_21k': 50}), (b['twin'], {'credit_21k': 50}),
               (b['purchases'], {'cash_debit': 21500}), (b['cash'], {'cash_credit': 21500})])          # bought
    _entry(3, [(b['display'], {'debit_21k': 120}), (b['supplier'], {'credit_21k': 120})])             # gold for gold
    _entry(4, [(b['supplier'], {'debit_21k': 120}), (b['scrap_safe'], {'credit_21k': 120})])          # paid in scrap
    _entry(5, [(b['display'], {'credit_21k': 80}), (b['customer'], {'debit_21k': 80})])               # sold
    _entry(6, [(b['scrap_safe'], {'debit_24k': 52.5}), (b['twin'], {'credit_24k': 52.5}),               # 60 g at the
               (b['purchases'], {'cash_debit': 27000}), (b['cash'], {'cash_credit': 27000})])          # main karat

    r = replay(opening_price=0.0, since=date(2032, 1, 1))

    month = r.months['2032-01']
    assert month.cost_of_worked_sold == pytest.approx(32800)
    assert month.sold_worked_g == pytest.approx(80)
    assert month.purchases_g == pytest.approx(210) and month.purchases_value == pytest.approx(88500)
    assert month.transfers_g == pytest.approx(120)
    assert month.exchange_difference == pytest.approx(0)
    assert r.pools['scrap'].avg == pytest.approx(436.67, abs=0.01) and r.pools['scrap'].weight == pytest.approx(90)
    assert r.pools['worked'].weight == pytest.approx(40) and r.pools['worked'].value == pytest.approx(16400)
    assert r.others == []
    assert r.days[3][1]['scrap'][0] == pytest.approx(30), 'paying the supplier in scrap moves nothing'


def test_a_reversed_sale_costs_nothing_in_its_own_month(books):
    """The rejected sale posted in August and reversed by an entry dated as it:
    its cost comes back in that month -- not a loss there and a gain elsewhere."""
    b = books
    _entry(1, [(b['scrap_safe'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (b['purchases'], {'cash_debit': 40000}), (b['cash'], {'cash_credit': 40000})])
    _entry(2, [(b['display'], {'debit_21k': 100}), (b['supplier'], {'credit_21k': 100})])
    sale = JournalEntry(entry_number=f'JE-G-{uuid.uuid4().hex[:8]}', date=datetime(2032, 1, 3, 10),
                        description='بيع', entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(sale)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=sale.id, account_id=b['display'].id, credit_21k=60),
                        JournalEntryLine(journal_entry_id=sale.id, account_id=b['customer'].id, debit_21k=60)])
    reversal = JournalEntry(entry_number=f'REV-G-{uuid.uuid4().hex[:8]}', date=datetime(2032, 2, 20, 10),
                            description='عكس', entry_type='عادي', reference_type='journal_entry_reversal',
                            reference_id=sale.id, is_posted=True, is_draft=False, created_by='t')
    db.session.add(reversal)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=reversal.id, account_id=b['display'].id, debit_21k=60),
                        JournalEntryLine(journal_entry_id=reversal.id, account_id=b['customer'].id, credit_21k=60)])
    db.session.flush()

    r = replay(opening_price=0.0, since=date(2032, 1, 1))

    assert r.months['2032-01'].cost_of_worked_sold == pytest.approx(0)
    assert r.months['2032-01'].sold_worked_g == pytest.approx(0)
    assert r.pools['worked'].weight == pytest.approx(100) and r.pools['worked'].avg == pytest.approx(400)


def test_the_opening_price_by_default_is_the_markets_average():
    """The owner (11 Oct 2026): entered by hand, else the market's average --
    over the first 30 days of prices from the opening on."""
    from models import GoldPrice
    from services.gold_cost import market_average_price
    for day, usd in ((5, 2000.0), (10, 2200.0), (20, 2400.0), (50, 9999.0)):      # the last is past the window
        db.session.add(GoldPrice(date=datetime(2033, 1, 1, 12) + __import__('datetime').timedelta(days=day), price=usd))
    db.session.flush()
    price, first, last = market_average_price(date(2033, 1, 1))
    per_gram_24k = 2200.0 / 31.1035 * 3.75
    assert price == pytest.approx(per_gram_24k * 21 / 24, abs=0.001)
    assert first == date(2033, 1, 6) and (last - first).days == 30


def test_by_the_nature_of_its_account_gold_is_an_expense_or_a_receivable(books):
    """The owner (11 Oct 2026): «اعتمد على طبيعة الحساب المسجل عليه الوزن». Gold
    to an expense account (752's subtree, by weight) is an expense; gold to a
    party's account (71 / 72 -- an employee, a partner, a dealer) is a
    receivable, not a cost. Neither is left for review."""
    b = books
    party = _child(_account('71'), 'حساب موظف وزني اختبار')     # a party's account, under 71
    expense = _child(_account('752'), 'مصروف وزني اختبار')
    _entry(1, [(b['scrap_safe'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (b['purchases'], {'cash_debit': 40000}), (b['cash'], {'cash_credit': 40000})])
    _entry(2, [(b['scrap_safe'], {'credit_21k': 30}), (party, {'debit_21k': 30})])        # an advance
    _entry(3, [(b['scrap_safe'], {'credit_21k': 5}), (expense, {'debit_21k': 5})])        # an expense
    _entry(4, [(b['scrap_safe'], {'debit_21k': 10}), (party, {'credit_21k': 10})])        # an advance repaid

    r = replay(opening_price=0.0, since=date(2032, 1, 1))

    m = r.months['2032-01']
    assert (m.receivables_g, m.receivables_value) == (pytest.approx(-20), pytest.approx(-8000))
    assert (m.expense_g, m.expense_value) == (pytest.approx(-5), pytest.approx(-2000))
    assert m.cost_of_worked_sold == 0 and m.cost_of_scrap_sold == 0
    assert r.others == []


def test_the_gross_by_cost_still_pays_the_making_charge(books):
    """The measure set revenue less the gold's cost beside the income statement's
    gross -- which also takes the making charge (510). On the 10 Oct copy that
    left 612,273 of wages out of one column and in the other (11 Oct 2026). The
    moving average replaces the gold's cost only; the wages stay a cost."""
    from services.gold_cost import gross_by_month
    b = books
    revenue = _child(_account('4'), 'إيراد اختبار')
    cost_of_sales = _account('51')
    _account('512').parent_id = cost_of_sales.id                # the purchases and the wages, under 51 as the chart has them
    wages = _child(_account('510', cost_of_sales), 'أجور اختبار')
    db.session.flush()
    _entry(1, [(b['scrap_safe'], {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (b['purchases'], {'cash_debit': 40000}), (b['cash'], {'cash_credit': 40000})])
    _entry(2, [(b['display'], {'debit_21k': 100}), (b['supplier'], {'credit_21k': 100})])
    _entry(3, [(b['display'], {'credit_21k': 60}), (b['customer'], {'debit_21k': 60}),
               (b['cash'], {'cash_debit': 30000}), (revenue, {'cash_credit': 30000}),
               (wages, {'cash_debit': 1500}), (b['cash'], {'cash_credit': 1500})])

    r = replay(opening_price=0.0, since=date(2032, 1, 1))
    m = gross_by_month(r)['2032-01']

    assert m['gold_cost'] == pytest.approx(24000)
    assert m['wages'] == pytest.approx(1500)
    assert m['gross_by_cost'] == pytest.approx(30000 - 24000 - 1500)
    assert m['gross_today'] == pytest.approx(30000 - 40000 - 1500), 'the purchase charged as it was bought'
