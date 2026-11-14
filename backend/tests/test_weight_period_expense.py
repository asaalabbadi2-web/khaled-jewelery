"""A period expense in the weight position (ADR-090, law 11; ADR-048).

The owner (14 Nov 2026), asked whether the closing is at the prepayment or at
each month's end: the riyal waits while it can still buy gold, and leaves the
queue the day it loses that -- the payment's day for a prepaid one (gone from
the drawer, never to come back), the month's end for an accrued one (owed
from then). The grams it took are measured that day, and borne by the months
the expense serves. An advance is riyals still waiting (16 Oct 2026); a
prepaid expense is not -- it does not come back.

Run:
    python -m pytest tests/test_weight_period_expense.py -v
"""
import datetime as dt
from datetime import date, datetime

import pytest

from services.weight_position import (
    EXPENSE, NOT_YET_DRAWN, Closing, Events, Lot, period_expense_timeline, replay, split_layers,
)


def _months(amount_h, *ends):
    return [(end, amount_h) for end in ends]


MONTH_ENDS = [date(2026, m, 28 if m == 2 else 30 if m in (4, 6, 9, 11) else 31) for m in range(1, 13)]


# ── the timeline: when the riyals leave, and what the months draw ─────────────

def test_an_accrued_expense_spends_its_riyals_at_each_months_end():
    closings, restores, draws = period_expense_timeline([], _months(1207500, *MONTH_ENDS[:5]))
    assert closings == [(end, 'accrued', 1207500) for end in MONTH_ENDS[:5]]
    assert restores == [] and draws == []


def test_the_june_rent_pays_off_what_was_owed_and_spends_june_ahead():
    payments = [(date(2026, 6, 24), 1, 7245000, None)]
    closings, _, draws = period_expense_timeline(payments, _months(1207500, *MONTH_ENDS[:6]))
    assert closings[-1] == (date(2026, 6, 24), 'prepaid', 1207500)     # January-May were spent when owed
    assert draws == [(date(2026, 6, 30), 1207500)]                     # June draws it, spends nothing more


def test_a_licence_paid_ahead_is_spent_on_payment_and_drawn_month_by_month():
    payments = [(date(2026, 1, 1), 1, 120000, None)]
    closings, restores, draws = period_expense_timeline(payments, _months(10000, *MONTH_ENDS))
    assert closings == [(date(2026, 1, 1), 'prepaid', 120000)]
    assert draws == [(end, 10000) for end in MONTH_ENDS] and restores == []


def test_a_payment_cancelled_gives_back_only_what_no_month_consumed():
    payments = [(date(2026, 1, 1), 1, 120000, date(2026, 11, 14))]
    closings, restores, draws = period_expense_timeline(payments, _months(10000, *MONTH_ENDS))
    assert restores == [(date(2026, 11, 14), 'prepaid', 20000)]        # ten months consumed, two back
    assert closings[-2:] == [(date(2026, 11, 30), 'accrued', 10000), (date(2026, 12, 31), 'accrued', 10000)]


def test_an_accrual_taken_back_returns_its_riyals_and_an_unconsumed_prepaid_month_its_draw():
    _, restores, _ = period_expense_timeline([], [(MONTH_ENDS[0], 10000), (MONTH_ENDS[1], -10000)])
    assert restores == [(MONTH_ENDS[1], 'accrued', 10000)]
    _, _, draws = period_expense_timeline([(date(2026, 1, 1), 1, 30000, None)],
                                          [(MONTH_ENDS[0], 20000), (MONTH_ENDS[1], -10000)])
    assert draws == [(MONTH_ENDS[0], 20000), (MONTH_ENDS[1], -10000)]


# ── the queue: the riyals leave on payment, the grams fall in the months ──────

def _at(day):
    return datetime.combine(day, dt.time(23, 59))


def _sale():
    return Lot('بيع', datetime(2025, 12, 31, 10, 0), 6000.0, 10.0, 600.0, invoice_id=1)


def _layer_four(result, month):
    lo = datetime(2026, month, 1)
    hi = datetime.combine(MONTH_ENDS[month - 1], dt.time.max)
    return split_layers([s for s in result.slices if lo <= s.when <= hi], [])['expense_cash']


def test_the_prepaid_riyals_leave_on_payment_and_each_month_bears_its_share():
    events = Events(openings=[_sale()],
                    closings=[Closing(_at(date(2026, 1, 1)), EXPENSE, 1200.0, tag=(7, 'prepaid'))],
                    draws=[(_at(end), 7, 100.0) for end in MONTH_ENDS])
    result = replay(events)
    assert result.lots[0].cash_open == pytest.approx(4800.0)                # gone from waiting on 1 January
    # 1,200 of 6,000 riyals of 10 g sold: 2 g, a twelfth a month.
    assert [round(_layer_four(result, m), 4) for m in (1, 6, 12)] == [-0.1667, -0.1667, -0.1667]
    assert sum(s.result for s in result.slices) == pytest.approx(-2.0)


def test_what_no_month_drew_yet_is_in_no_months_profit_but_not_waiting_either():
    events = Events(openings=[_sale()],
                    closings=[Closing(_at(date(2026, 1, 1)), EXPENSE, 1200.0, tag=(7, 'prepaid'))],
                    draws=[(_at(MONTH_ENDS[0]), 7, 100.0)])
    result = replay(events)
    assert result.lots[0].cash_open == pytest.approx(4800.0)
    assert round(_layer_four(result, 1), 4) == -0.1667
    pending = [s for s in result.slices if s.when == NOT_YET_DRAWN]
    assert sum(s.result for s in pending) == pytest.approx(-2.0 + 0.1667, abs=1e-3)
    assert all(s.happened == _at(date(2026, 1, 1)) for s in pending)          # spent on the payment's day


def test_a_cancelled_payment_comes_back_to_waiting_with_the_grams_it_took():
    events = Events(openings=[_sale()],
                    closings=[Closing(_at(date(2026, 1, 1)), EXPENSE, 1200.0, tag=(7, 'prepaid'))],
                    restores=[(_at(date(2026, 3, 1)), (7, 'prepaid'), 1200.0)])
    result = replay(events)
    assert sum(s.result for s in result.slices) == pytest.approx(0.0)      # no expense left
    assert [s for s in result.slices if s.when == NOT_YET_DRAWN and s.cash > 0.005] == []
    assert result.month_end['2026-03'] == pytest.approx((6000.0, 10.0))     # all waiting again, with its grams


# ── the books: the month entries are not read twice ───────────────────────────

@pytest.fixture(scope='module')
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def fenced(app, db_fence):
    yield


def test_a_period_expense_reaches_the_queue_once_from_itself(fenced, auth_headers, vworld, books):
    from models import Account, db
    from services.period_expense import accrue
    from services.weight_position import collect_events
    from tests.period_expense_world import expense, pay
    from tests.voucher_world import auto_post
    Account.query.filter_by(account_number='52').one().include_in_gram_profit = True
    db.session.flush()
    auto_post(True)
    licence = expense(books, amount=1200, description='رخصة')
    assert pay(auth_headers, books, licence, 1200, date(2026, 1, 1)).status_code == 201
    accrue(date(2026, 3, 31), by='t', now=datetime(2026, 4, 1), dry_run=False)
    events = collect_events(datetime(2026, 1, 1), datetime(2026, 3, 31, 23, 59, 59))
    expense_closings = [c for c in events.closings if c.kind == EXPENSE]
    # The payment once, prepaid, on its day; the three months only as draws -- not as expenses again.
    assert [(c.when.date(), c.cash, c.tag) for c in expense_closings] == [(date(2026, 1, 1), 1200.0, (licence.id, 'prepaid'))]
    assert [(d[0].date(), d[2]) for d in events.draws] == [(MONTH_ENDS[0], 100.0), (MONTH_ENDS[1], 100.0),
                                                            (MONTH_ENDS[2], 100.0)]


from tests.period_expense_world import books  # noqa: E402,F401 (fixture)
from tests.voucher_world import vworld  # noqa: E402,F401 (fixture)
