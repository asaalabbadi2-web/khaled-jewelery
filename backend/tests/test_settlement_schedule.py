"""A settlement is dated the day its money reaches the bank (ADR-037, the owner 6 Oct 2026).

«يهمني أن يطابق كشف بنك الرياض الدفاتر بتاريخ كل حركة». The three methods as
the owner described them:

- Mada: the POS batch closes at midnight and reaches the bank the next day
  (his bank deposits on its weekend; other banks do not -- the weekend is an
  option, and so are the public holidays);
- Tamara: everything before Saturday is settled on Saturday and deposited on
  Wednesday; the flexible plan holds it until the net reaches a minimum;
- Tabby: every Monday, the sales up to Sunday 11:59 pm, whatever the amount
  (fixed plan) -- a flexible plan is a setting away.

Pure: services/settlement_schedule.py has no clock and no database.

Run:
    python -m pytest tests/test_settlement_schedule.py -v
"""
from datetime import date

import pytest

from services.settlement_schedule import (
    Schedule, ScheduleInvalid, batch_close, deposit_for_sale, describe, due_deposits, parse_weekend,
    preview, validate,
)

# October 2026: Sunday the 4th.
SUN4, MON5, TUE6, WED7, THU8, FRI9, SAT10 = (date(2026, 10, d) for d in range(4, 11))
SUN11, MON12, WED14, MON19, WED21 = date(2026, 10, 11), date(2026, 10, 12), date(2026, 10, 14), \
    date(2026, 10, 19), date(2026, 10, 21)

MADA = Schedule(period='daily', close_weekday=None, deposit_rule='after_days', deposit_days=1, deposit_weekday=None)
TAMARA = Schedule(period='weekly', close_weekday=4, deposit_rule='weekday', deposit_days=0, deposit_weekday=2,
                  min_net=2500.0)
TABBY = Schedule(period='weekly', close_weekday=6, deposit_rule='weekday', deposit_days=0, deposit_weekday=0)


def _gross(gross, count):
    return gross


# ── the deposit day ──────────────────────────────────────────────────────────

def test_mada_reaches_the_bank_the_next_day_weekend_included():
    assert [deposit_for_sale(MADA, d) for d in (THU8, FRI9, SAT10)] == [FRI9, SAT10, SUN11]


def test_a_bank_closed_on_its_weekend_deposits_on_the_next_working_day():
    closed = Schedule(**{**MADA.__dict__, 'weekend': frozenset({4, 5})})   # Friday, Saturday
    assert [deposit_for_sale(closed, d) for d in (WED7, THU8, FRI9, SAT10)] == [THU8, SUN11, SUN11, SUN11]


def test_a_public_holiday_moves_the_deposit_only_when_the_method_skips_holidays():
    holiday = frozenset({SUN11})
    assert deposit_for_sale(MADA, SAT10, holiday) == SUN11
    skipping = Schedule(**{**MADA.__dict__, 'skip_holidays': True})
    assert deposit_for_sale(skipping, SAT10, holiday) == MON12


def test_tamara_everything_before_saturday_reaches_the_bank_on_wednesday():
    assert batch_close(TAMARA, SAT10) == date(2026, 10, 16)       # its batch ends on Friday the 16th
    assert deposit_for_sale(TAMARA, SUN4) == WED14
    assert deposit_for_sale(TAMARA, FRI9) == WED14
    assert deposit_for_sale(TAMARA, SAT10) == WED21


def test_tabby_monday_carries_the_sales_up_to_sunday():
    assert deposit_for_sale(TABBY, SUN11) == MON12
    assert deposit_for_sale(TABBY, MON5) == MON12
    assert deposit_for_sale(TABBY, MON12) == MON19


# ── what is due ──────────────────────────────────────────────────────────────

def test_a_deposit_not_yet_reached_is_not_due_and_one_reached_is_dated_its_day():
    pays = [(1, MON5, 100.0), (2, TUE6, 50.0)]
    assert due_deposits(MADA, pays, as_of=MON5, net_of=_gross) == []
    dues = due_deposits(MADA, pays, as_of=WED7, net_of=_gross)
    assert [(d.deposit_date, d.payments) for d in dues] == [(TUE6, [(1, 100.0)]), (WED7, [(2, 50.0)])]


def test_a_late_run_dates_the_deposit_not_the_run():
    """The scheduler stopped for three days: what it settles is still dated
    the day each deposit reached the bank."""
    dues = due_deposits(TABBY, [(1, TUE6, 900.0)], as_of=date(2026, 10, 15), net_of=_gross)
    assert [d.deposit_date for d in dues] == [MON12]


def test_one_deposit_carries_its_whole_batch():
    pays = [(1, SAT10, 300.0), (2, MON5, 1000.0), (3, SUN11, 200.0)]
    dues = due_deposits(TABBY, pays, as_of=MON12, net_of=_gross)
    assert len(dues) == 1 and dues[0].deposit_date == MON12 and dues[0].gross == 1500.0
    assert dues[0].first_sale_day == MON5


def test_a_flexible_plan_holds_until_the_net_together_reaches_the_minimum():
    """Tamara, minimum 2,500 net: a 1,000 week waits; with the next 2,000 week
    the two travel together on the second Wednesday -- one deposit."""
    pays = [(1, MON5, 1000.0), (2, MON12, 2000.0)]
    assert due_deposits(TAMARA, pays, as_of=WED14, net_of=_gross) == []
    dues = due_deposits(TAMARA, pays, as_of=WED21, net_of=_gross)
    assert len(dues) == 1 and dues[0].deposit_date == WED21 and dues[0].gross == 3000.0
    assert dues[0].first_sale_day == MON5


def test_the_minimum_is_on_the_net_not_the_gross():
    """2,600 gross less 6% commission is 2,444 net: below 2,500, it waits."""
    net = lambda gross, count: round(gross * 0.94, 2)   # noqa: E731
    assert due_deposits(TAMARA, [(1, MON5, 2600.0)], as_of=WED14, net_of=net) == []
    assert due_deposits(TAMARA, [(1, MON5, 2700.0)], as_of=WED14, net_of=net)


def test_a_fixed_plan_deposits_whatever_the_amount():
    assert due_deposits(TABBY, [(1, MON5, 10.0)], as_of=MON12, net_of=_gross)[0].gross == 10.0


# ── the settings ─────────────────────────────────────────────────────────────

@pytest.mark.parametrize('bad', [
    dict(period='weekly', close_weekday=None),
    dict(deposit_rule='weekday', deposit_weekday=None),
    dict(deposit_days=31),
    dict(weekend=frozenset(range(7))),
    dict(deposit_rule='weekday', deposit_weekday=4, weekend=frozenset({4, 5})),
    dict(min_net=-1.0),
])
def test_a_schedule_that_cannot_be_read_is_refused(bad):
    with pytest.raises(ScheduleInvalid):
        validate(Schedule(**{**MADA.__dict__, **bad}))


def test_the_weekend_is_read_and_refused_out_of_range():
    assert parse_weekend('4, 5') == frozenset({4, 5}) and parse_weekend('') == frozenset()
    with pytest.raises(ScheduleInvalid):
        parse_weekend('7')


def test_the_screens_read_the_same_schedule():
    assert describe(TAMARA).startswith('دفعة أسبوعية تُقفل نهاية الجمعة · تُودَع الأربعاء التالي')
    assert 'خطة مرنة' in describe(TAMARA) and 'خطة ثابتة' in describe(TABBY)
    rows = preview(TABBY, MON5, days=7)
    assert {r['deposit_day'] for r in rows} == {MON12.isoformat()}
