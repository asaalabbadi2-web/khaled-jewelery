"""ADR-042: the transition -- the year that starts on the moving average starts with its stock right.

The owner (11 Oct 2026): «لا تصلح ما سبق فيما يخص قائمة الدخل ... السنة الجديدة
نبدأها بشكل سليم». So no month before the transition is adjusted: one entry,
dated the transition's first instant, brings the financial stock to the pools'
value and clears what the old model left on the balance sheet -- the suppliers'
gold written in riyals on 2100, cash written on a pool's weight account -- and
the difference goes to equity, 33 «فروقات تقييم الذهب». No income-statement
account moves.

The worked example, by hand:
  1 Jan    opening: 100 g worked at 400
  5 Jan    50 g of scrap bought for 21,000 (512)            -> scrap 50 g, avg 420
  10 Jan   60 g worked sold                                  -> worked 40 g, 16,000
  3 Feb    40 g worked from a supplier for gold -- and, the old way, its value
           in riyals: 1300 18,000 / 2100 18,000 (the gold owed, twice)
           -> 40 g moves scrap to worked at 420: worked 80 g, 32,800
  10 Feb   2 g of scrap to an expense; 12 Feb 5 g to a party -> scrap 3 g, 1,260
  1 Mar    the transition: 1300 +14,800 (18,000 -> 32,800), 1310 +1,260,
           2100 +18,000, 33 -34,060; 512 keeps its 21,000

Run:
    python -m pytest tests/test_gold_cost_books.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from services.gold_cost_books import TRANSITION, NotAsMeasured, cost_basis, plan_transition, write_transition


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


NOW = datetime(2032, 3, 2, 9, 0)
SINCE, AT = date(2032, 1, 1), date(2032, 3, 1)


def _account(number, kind='Asset', weight=False):
    found = Account.query.filter_by(account_number=number).first()
    if found:
        return found
    a = Account(account_number=number, name=f'ح {number}', type=kind, tracks_weight=weight)
    db.session.add(a)
    db.session.flush()
    return a


def _child(root, tag, weight=True, kind='Asset'):
    a = Account(account_number=f'{root.account_number}8{uuid.uuid4().int % 10**5}', name=tag, type=kind,
                tracks_weight=weight, parent_id=root.id)
    db.session.add(a)
    db.session.flush()
    return a


def _entry(month, day, lines):
    je = JournalEntry(entry_number=f'JE-B-{uuid.uuid4().hex[:8]}', date=datetime(2032, month, day, 10),
                      description='اختبار', entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='اختبار', **cols))
    db.session.flush()
    return je


@pytest.fixture
def books():
    _account('33', kind='Equity')
    b = {
        'display': _child(_account('71300', weight=True), 'معروض اختبار'),
        'scrap_safe': _child(_account('71310', weight=True), 'صندوق كسر اختبار'),
        'supplier': _child(_account('7210', weight=True), 'مورد اختبار وزني', kind='Liability'),
        'customer': _child(_account('7120', weight=True), 'عميل اختبار وزني'),
        'party': _child(_account('71', weight=True), 'موظف اختبار وزني'),
        'expense': _child(_account('752', kind='Expense', weight=True), 'مصروف اختبار وزني', kind='Expense'),
        'equity': _child(_account('73', weight=True), 'رأس مال اختبار وزني', kind='Equity'),
        'twin': _child(_account('7512', weight=True), 'مشتريات اختبار وزني', kind='Expense'),
        'purchases': _account('512', kind='Expense'),
        'stock_worked': _account('1300'), 'stock_scrap': _account('1310'),
        'suppliers_value': _account('2100', kind='Liability'),
        'cash': _child(_account('1100'), 'صندوق اختبار', weight=False),
    }
    _entry(1, 1, [(b['display'], {'debit_21k': 100}), (b['equity'], {'credit_21k': 100})])
    _entry(1, 5, [(b['scrap_safe'], {'debit_21k': 50}), (b['twin'], {'credit_21k': 50}),
                  (b['purchases'], {'cash_debit': 21000}), (b['cash'], {'cash_credit': 21000})])
    _entry(1, 10, [(b['display'], {'credit_21k': 60}), (b['customer'], {'debit_21k': 60})])
    _entry(2, 3, [(b['display'], {'debit_21k': 40}), (b['supplier'], {'credit_21k': 40}),
                  (b['stock_worked'], {'cash_debit': 18000}), (b['suppliers_value'], {'cash_credit': 18000})])
    _entry(2, 10, [(b['scrap_safe'], {'credit_21k': 2}), (b['expense'], {'debit_21k': 2})])
    _entry(2, 12, [(b['scrap_safe'], {'credit_21k': 5}), (b['party'], {'debit_21k': 5})])
    return b


def _write(dry_run=False, price=400.0, now=NOW, at=AT):
    return write_transition(by='t', now=now, opening_price=price, at=at, since=SINCE, dry_run=dry_run)


def _cash(account):
    q = (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(JournalEntryLine.account_id == account.id, JournalEntryLine.is_deleted.is_(False),
                 JournalEntry.is_posted.is_(True), JournalEntry.date >= datetime(2032, 1, 1)))
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in q), 2)


def test_the_plan_reads_the_worked_example(books):
    plan = plan_transition(opening_price=400.0, at=AT, since=SINCE)
    assert plan['date'] == datetime(2032, 3, 1)
    assert plan['lines'] == {'1300': pytest.approx(14800), '1310': pytest.approx(1260),
                             '2100': pytest.approx(18000), '33': pytest.approx(-34060)}


def test_written_the_stock_is_the_pools_and_no_income_account_moves(books):
    b = books
    assert _write(dry_run=True)['written'] == [] and not JournalEntry.query.filter_by(reference_type=TRANSITION).filter(
        JournalEntry.date >= datetime(2032, 1, 1)).first(), 'a dry run writes nothing'

    done = _write()

    assert len(done['written']) == 1
    entry = JournalEntry.query.filter_by(entry_number=done['written'][0]).one()
    assert entry.date == datetime(2032, 3, 1), 'the new period\'s first instant: the old one is not touched'
    assert _cash(b['stock_worked']) == pytest.approx(32800), '80 g worked: 40 at 400, 40 at 420'
    assert _cash(b['stock_scrap']) == pytest.approx(1260), '3 g of scrap at 420'
    assert _cash(b['suppliers_value']) == pytest.approx(0), 'the gold owed is owed in gold, once'
    assert _cash(b['purchases']) == pytest.approx(21000), 'the past\'s income statement as it was'
    again = _write()
    assert again['written'] == [] and again['drift'] == {}, 'a second run writes nothing and finds it right'


def test_cash_on_a_pools_weight_account_is_moved_out(books):
    """An office reservation's price was written on 71310's weight account (stage-4 item 15)."""
    b = books
    _entry(2, 15, [(b['scrap_safe'], {'cash_debit': 500}), (b['cash'], {'cash_credit': 500})])
    lines = plan_transition(opening_price=400.0, at=AT, since=SINCE)['lines']
    assert lines[b['scrap_safe'].account_number] == pytest.approx(-500)
    assert round(sum(lines.values()), 2) == 0


def test_a_back_dated_entry_after_the_transition_gets_a_further_entry(books):
    """A stage-4 repair dated as its document moves the stock before the
    transition: the next run writes the difference, never an edit."""
    b = books
    _write()
    _entry(2, 20, [(b['scrap_safe'], {'debit_21k': 10}), (b['twin'], {'credit_21k': 10}),
                   (b['purchases'], {'cash_debit': 4300}), (b['cash'], {'cash_credit': 4300})])
    assert _write(dry_run=True)['drift'] == {'1310': pytest.approx(4300), '33': pytest.approx(-4300)}
    assert len(_write()['written']) == 1
    assert len(JournalEntry.query.filter_by(reference_type=TRANSITION).filter(
        JournalEntry.date == datetime(2032, 3, 1)).all()) == 2
    assert _cash(b['stock_scrap']) == pytest.approx(1260 + 4300)
    assert _write(dry_run=True)['drift'] == {}


def test_every_line_balances_to_the_cent(books):
    b = books
    _entry(2, 21, [(b['scrap_safe'], {'debit_21k': 3}), (b['twin'], {'credit_21k': 3}),
                   (b['purchases'], {'cash_debit': 1000.003}), (b['cash'], {'cash_credit': 1000.003})])
    _entry(2, 22, [(b['scrap_safe'], {'credit_21k': 1.333}), (b['party'], {'debit_21k': 1.333})])
    assert round(sum(plan_transition(opening_price=400.0, at=AT, since=SINCE)['lines'].values()), 2) == 0
    _write()


def test_the_transition_is_a_first_day_that_has_come(books):
    with pytest.raises(NotAsMeasured):
        _write(now=datetime(2032, 2, 20))
    with pytest.raises(NotAsMeasured):
        _write(at=date(2032, 2, 15))


def test_an_opening_price_that_moved_is_refused(books):
    _write()
    with pytest.raises(NotAsMeasured):
        _write(dry_run=True, price=410.0)


def test_the_income_statement_says_which_basis_its_period_is_on(books):
    assert cost_basis(datetime(2032, 1, 1), datetime(2032, 4, 1))[0] == 'purchases'
    _write()
    assert cost_basis(datetime(2032, 1, 1), datetime(2032, 3, 1))[0] == 'purchases', 'the past as it was'
    basis, note = cost_basis(datetime(2032, 3, 1), datetime(2032, 4, 1))
    assert basis == 'moving_average' and 'متوسط' in note
    basis, note = cost_basis(datetime(2032, 2, 1), datetime(2032, 4, 1))
    assert basis == 'mixed' and '2032-03-01' in note
