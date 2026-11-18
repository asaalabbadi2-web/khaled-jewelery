"""A correction that takes an expense or a revenue back moves the weight profit (the owner, 19 Nov 2026).

«لما لم يؤثر اخر قيد في الربح الوزني؟» -- JE-2026-07814 took 63,676.73 of
wages booked too much off «510 مصروفات أجور المصنعية», and JE-2026-07813 moved
86,231.27 from «440 فائض أجور المصنعية» to 510; both dated 19 Nov. The engine
summed each day's marked expenses and revenues and kept a day only above
nothing: that day's -149,908.00 of expense and -86,231.27 of revenue were
dropped, and November's weight profit read 342.454 g with them or without
(the 19 Nov copy). Now:
  - a day's expenses less than nothing are riyals that never left: back to
    waiting with no grams sold, read in ④ when they turn into gold;
  - a day's revenues less than nothing are riyals that never came: out of
    waiting, read in ②;
  - so the queue reads as if the expense, or the revenue, had not been.

Run:
    python -m pytest tests/test_weight_position_takes_a_correction.py -v
"""
import datetime as dt
import uuid

import pytest

from services.weight_position import (CUSTOMER, EXPENSE, EXPENSE_BACK, REVENUE, REVENUE_BACK, Closing, Events, Lot,
                                      replay, split_layers)

D = dt.datetime


def _whole(result):
    return sum(s.result for s in result.slices) + sum(d[1] for d in result.direct)


def _sale():
    return Lot('بيع', D(2031, 3, 1, 10), 6000, 10, 500)


def test_an_expense_taken_back_is_as_if_it_had_not_been():
    """Sold 10 g for 6,000; 600 spent, then taken back; the rest turned into gold at 500."""
    taken_back = replay(Events(openings=[_sale(), Lot('نقص مصروفات', D(2031, 3, 3, 23, 59), 600, 0.0,
                                                      kind=EXPENSE_BACK)],
                               closings=[Closing(D(2031, 3, 2), EXPENSE, 600),
                                         Closing(D(2031, 3, 4), CUSTOMER, 6000, 12.0)]))
    never = replay(Events(openings=[_sale()], closings=[Closing(D(2031, 3, 4), CUSTOMER, 6000, 12.0)]))
    assert _whole(taken_back) == pytest.approx(_whole(never)) == pytest.approx(2.0)
    layers = split_layers(taken_back.slices, taken_back.direct, lambda day: (500.0, 'سعر'))
    assert sum(layers.values()) == pytest.approx(2.0)
    assert layers['expense_cash'] == pytest.approx(0.0), 'the 600 spent and taken back: no expense in ④'


def test_a_purchase_turns_the_riyals_taken_back_into_gold_first():
    """As a revenue's: 600 back waiting, a purchase of 600 takes them before the
    sale's -- the expense and its taking back meet in ④, at nothing."""
    result = replay(Events(openings=[_sale(), Lot('نقص مصروفات', D(2031, 3, 3, 23, 59), 600, 0.0,
                                                  kind=EXPENSE_BACK)],
                           closings=[Closing(D(2031, 3, 2), EXPENSE, 600),
                                     Closing(D(2031, 3, 4), CUSTOMER, 600, 1.2)]))
    layers = split_layers(result.slices, result.direct, lambda day: (500.0, 'سعر'))
    assert layers['expense_cash'] == pytest.approx(0.0)
    assert [l.cash_open for l in result.open_lots] == [pytest.approx(5400.0)], 'the sale\'s riyals still wait'


def test_a_revenue_taken_back_is_as_if_it_had_not_been():
    taken_back = replay(Events(openings=[_sale(), Lot('إيرادات', D(2031, 3, 1, 23), 500, 0.0, kind=REVENUE)],
                               closings=[Closing(D(2031, 3, 2, 23, 59), REVENUE_BACK, 500),
                                         Closing(D(2031, 3, 4), CUSTOMER, 6000, 12.0)]))
    assert _whole(taken_back) == pytest.approx(2.0)
    layers = split_layers(taken_back.slices, taken_back.direct, lambda day: (500.0, 'سعر'))
    assert layers['revenue_converted'] == pytest.approx(0.0)
    assert not taken_back.open_lots


def test_the_owner_s_day_both_taken_back_the_difference_waits():
    """As 19 Nov: 1,500 of expense and 900 of revenue taken back the same day --
    600 more riyals waiting, 1.2 g more at 500."""
    result = replay(Events(openings=[_sale(), Lot('نقص مصروفات', D(2031, 3, 2, 23, 59), 1500, 0.0,
                                                  kind=EXPENSE_BACK)],
                           closings=[Closing(D(2031, 3, 2, 23, 59), REVENUE_BACK, 900),
                                     Closing(D(2031, 3, 4), CUSTOMER, 6600, 13.2)]))
    assert _whole(result) == pytest.approx((6000 + 1500 - 900) / 500 - 10)


# ── from the books ─────────────────────────────────────────────────────────

@pytest.fixture(scope='module')
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def test_the_books_take_back_a_day_below_nothing(app):
    """A day's marked expense credited past its debits, and a revenue debited
    past its credits: neither is dropped any more."""
    from accounting.chart_tree import EXPENSES_ROOT, REVENUE_ROOT, role_account_id
    from models import Account, JournalEntry, JournalEntryLine, db
    from services.weight_position import collect_events

    def account(root, kind):
        a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name=f'حساب {uuid.uuid4().hex[:4]}', type=kind,
                    parent_id=role_account_id(root) if root else None, transaction_type='cash', tracks_weight=False)
        db.session.add(a)
        db.session.flush()
        return a
    expense, revenue, other = account(EXPENSES_ROOT, 'Expense'), account(REVENUE_ROOT, 'Revenue'), account(None, 'Asset')
    je = JournalEntry(entry_number=f'JE-WC-{uuid.uuid4().hex[:6]}', date=D(2036, 5, 19, 0, 30), description='تصحيح',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=expense.id, cash_debit=100.0),
        JournalEntryLine(journal_entry_id=je.id, account_id=expense.id, cash_credit=700.0),   # 600 below nothing
        JournalEntryLine(journal_entry_id=je.id, account_id=revenue.id, cash_debit=250.0),    # 250 below nothing
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=850.0, cash_credit=0.0)])
    db.session.flush()
    events = collect_events(D(2036, 5, 1), D(2036, 5, 31, 23, 59))
    assert [(l.kind, round(l.cash, 2)) for l in events.openings if l.kind == EXPENSE_BACK] == [(EXPENSE_BACK, 600.0)]
    assert [(c.kind, round(c.cash, 2)) for c in events.closings if c.kind == REVENUE_BACK] == [(REVENUE_BACK, 250.0)]
    assert not [c for c in events.closings if c.kind == EXPENSE], 'the day nets: no expense is spent that day'


# ── riyals a period expense gives back wait where they are seen (audit, 19 Nov 2026) ──
#
# The audit of the 19 Nov copy: 50,395 riyals given back by period expenses
# (four rent accruals restated, PV-2026-01574 cancelled on 17 Nov) went back
# into the queue as lots of their own, but not into the replay's lots -- 2,095
# still waiting were in no «what waits», no ⑤; the year by month and the year
# as one period read 1.078 g apart.

def test_riyals_given_back_wait_where_they_are_seen():
    from services.weight_position import sale_view
    events = Events(openings=[Lot('بيع', D(2031, 3, 1, 10), 6000, 10, 500, invoice_id=7)],
                    closings=[Closing(D(2031, 3, 2, 23, 59), EXPENSE, 2095, tag=(17, 'prepaid'))],
                    restores=[(D(2031, 3, 3, 23, 59), (17, 'prepaid'), 2095)])
    result = replay(events)
    assert sum(l.cash_open for l in result.open_lots) == pytest.approx(6000.0), 'as if never spent'
    assert sum(l.grams_open for l in result.open_lots) == pytest.approx(10.0)
    view = sale_view(result, events, 7, 500.0)
    assert view['cash_open'] == pytest.approx(6000.0)
    assert sum(view['shares'].values()) == pytest.approx(1.0), 'its riyals all somewhere'


def test_a_marked_cash_accounts_grams_are_read_in_every_karat(app):
    """Read in 21k alone, a weight on a marked cash account's 18k column was
    dropped -- none on the 19 Nov copy, but a karat fixed in the code (the
    owner: the main karat from the settings only). Every karat, at its purity."""
    from accounting.chart_tree import EXPENSES_ROOT, role_account_id
    from models import Account, JournalEntry, JournalEntryLine, db
    from pricing.karat_service import get_main_karat
    from services.weight_position import EXPENSE_SIDE, collect_events
    expense = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name='مصروف نقدي', type='Expense',
                      parent_id=role_account_id(EXPENSES_ROOT), transaction_type='cash', tracks_weight=False)
    other = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name='مقابل', type='Asset',
                    transaction_type='cash', tracks_weight=False)
    db.session.add_all([expense, other])
    db.session.flush()
    je = JournalEntry(entry_number=f'JE-WK-{uuid.uuid4().hex[:6]}', date=D(2036, 6, 3, 10), description='وزن',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=expense.id, debit_18k=7.0),
                        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, credit_18k=7.0)])
    db.session.flush()
    events = collect_events(D(2036, 6, 1), D(2036, 6, 30, 23, 59))
    main = float(get_main_karat())
    assert [(round(g, 4), side) for _, g, side in events.direct] == [(round(-7.0 * 18 / main, 4), EXPENSE_SIDE)]


def test_what_the_queue_set_aside_is_said_not_left_out_in_silence():
    """Riyals spent with no sale's open (a scrap bought with cash from before,
    142,293.58 riyals of April on the 19 Nov copy) are not in the weight profit
    -- by design (ADR-048) -- and are said with it, as the returns that came
    after their sale was closed are."""
    from services.weight_position import set_aside
    result = replay(Events(openings=[Lot('بيع', D(2031, 3, 1, 10), 1000, 2, 500, invoice_id=9)],
                           closings=[Closing(D(2031, 3, 2), CUSTOMER, 1000, 2.0),
                                     Closing(D(2031, 3, 3), CUSTOMER, 600, 1.2)],
                           returns=[__import__('services.weight_position', fromlist=['Return']).Return(
                               D(2031, 3, 4), 9, 500, 1.0)]))
    said = set_aside(result, D(2031, 3, 1), D(2031, 3, 31, 23, 59))
    assert (said['cash'], said['grams'], said['count']) == (600.0, 1.2, 1)
    assert said['returns_after_closing'] == 1
