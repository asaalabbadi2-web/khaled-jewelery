"""When a clearing method's money reaches the bank, and what each deposit carries (ADR-037).

The one reading of a payment method's settlement schedule. The scheduler
settles by it, the overdue alarm alarms by it, and the settings screen previews
it -- none restates it.

The owner (6 Oct 2026): «يهمني أن يطابق كشف بنك الرياض الدفاتر بتاريخ كل حركة».
So a settlement is dated the day its money reaches the bank, and one
settlement is one deposit. Four questions describe a method (POLICY -- its
settings, changed from the screen):

  1. the batch: daily (closes at midnight), or weekly (closes at the end of a
     given weekday: Tamara Friday, Tabby Sunday);
  2. the deposit: N days after the batch closes (Mada 1), or the first given
     weekday after it (Tamara Wednesday, Tabby Monday);
  3. days the bank deposits nothing: its weekend (optional, per method) and
     the public holidays (optional, one calendar) -- the deposit moves to the
     next day that is neither;
  4. a minimum: none (a fixed plan), or a NET amount the held batches must
     reach together (a flexible plan) -- below it they wait and join the next
     deposit.

The LAWS (tests/test_settlement_schedule.py): a settlement is dated its deposit
day -- never the sale day, never the hour the scheduler ran; one per deposit
(one per batch, held batches joining the next); the minimum is on the net of
all that is held, not on each day.

Weekdays are Python's: 0 = Monday ... 6 = Sunday. Pure: no clock, no database
-- the caller passes the day and the holidays.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Callable, FrozenSet, Iterable, List, Optional, Sequence, Tuple

WEEKDAYS_AR = ('الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد')
_MAX_ROLL_DAYS = 60   # a deposit day further than this from its batch is a misconfiguration


class ScheduleInvalid(ValueError):
    """A schedule that cannot be read; the message is Arabic, for the screen."""


@dataclass(frozen=True)
class Schedule:
    period: str                      # 'daily' | 'weekly'
    close_weekday: Optional[int]     # weekly: the last day in the batch
    deposit_rule: str                # 'after_days' | 'weekday'
    deposit_days: int                # after_days: days from the batch's close
    deposit_weekday: Optional[int]   # weekday: the deposit's weekday
    weekend: FrozenSet[int] = frozenset()
    skip_holidays: bool = False
    min_net: float = 0.0             # 0: fixed plan; > 0: flexible plan


@dataclass
class Due:
    """One deposit: the batches it carries and the payments in them."""
    close_date: date                 # the last batch's close
    deposit_date: date
    first_sale_day: date
    payments: List[Tuple[int, float]] = field(default_factory=list)   # (invoice_payment_id, open amount)

    @property
    def gross(self) -> float:
        return round(sum(a for _, a in self.payments), 2)


def parse_weekend(raw) -> FrozenSet[int]:
    """'4,5' -> {4, 5}. Empty, None -> no weekend."""
    if raw in (None, ''):
        return frozenset()
    days = set()
    for part in str(raw).replace(' ', '').split(','):
        if part == '':
            continue
        try:
            day = int(part)
        except ValueError:
            raise ScheduleInvalid('أيام عطلة البنك غير صالحة')
        if day < 0 or day > 6:
            raise ScheduleInvalid('أيام عطلة البنك يجب أن تكون بين 0 و 6')
        days.add(day)
    return frozenset(days)


def format_weekend(days: Iterable[int]) -> str:
    return ','.join(str(d) for d in sorted(set(days)))


def schedule_of(pm) -> Schedule:
    """A PaymentMethod's schedule, from its columns (the column names predate
    ADR-037: settlement_schedule_type 'days'|'weekday' is the batch period,
    settlement_weekday the weekly batch's last day, deposit_schedule_type
    'days'|'weekday' the deposit rule, deposit_delay_days its N)."""
    period = 'weekly' if str(getattr(pm, 'settlement_schedule_type', 'days') or 'days').lower() == 'weekday' else 'daily'
    rule = 'weekday' if str(getattr(pm, 'deposit_schedule_type', 'days') or 'days').lower() == 'weekday' else 'after_days'
    return Schedule(
        period=period,
        close_weekday=getattr(pm, 'settlement_weekday', None),
        deposit_rule=rule,
        deposit_days=int(getattr(pm, 'deposit_delay_days', 0) or 0),
        deposit_weekday=getattr(pm, 'deposit_weekday', None),
        weekend=parse_weekend(getattr(pm, 'bank_weekend_days', '') or ''),
        skip_holidays=bool(getattr(pm, 'skip_public_holidays', False)),
        min_net=float(getattr(pm, 'min_settlement_amount', 0.0) or 0.0),
    )


def validate(s: Schedule) -> Schedule:
    if s.period not in ('daily', 'weekly'):
        raise ScheduleInvalid('نوع الدفعة يجب أن يكون يومية أو أسبوعية')
    if s.period == 'weekly' and (s.close_weekday is None or not 0 <= int(s.close_weekday) <= 6):
        raise ScheduleInvalid('حدّد آخر يوم في الدفعة الأسبوعية')
    if s.deposit_rule not in ('after_days', 'weekday'):
        raise ScheduleInvalid('طريقة الإيداع يجب أن تكون بعد عدد أيام أو في يوم محدد')
    if s.deposit_rule == 'weekday' and (s.deposit_weekday is None or not 0 <= int(s.deposit_weekday) <= 6):
        raise ScheduleInvalid('حدّد يوم الإيداع')
    if s.deposit_rule == 'after_days' and not 0 <= int(s.deposit_days) <= 30:
        raise ScheduleInvalid('أيام الإيداع يجب أن تكون بين 0 و 30')
    if len(s.weekend) >= 7:
        raise ScheduleInvalid('لا يمكن أن تكون أيام الأسبوع كلها عطلة')
    if s.deposit_rule == 'weekday' and s.deposit_weekday in s.weekend:
        raise ScheduleInvalid('يوم الإيداع من أيام عطلة البنك')
    if s.min_net < 0:
        raise ScheduleInvalid('الحد الأدنى لا يكون سالبًا')
    return s


# ── the days ─────────────────────────────────────────────────────────────────

def batch_close(s: Schedule, sale_day: date) -> date:
    """The day the batch holding *sale_day* closes (at its midnight)."""
    if s.period == 'daily':
        return sale_day
    ahead = (int(s.close_weekday) - sale_day.weekday()) % 7
    return sale_day + timedelta(days=ahead)


def deposit_day(s: Schedule, close: date, holidays: FrozenSet[date] = frozenset()) -> date:
    """The day a batch closed on *close* reaches the bank."""
    if s.deposit_rule == 'weekday':
        day = close + timedelta(days=1)
        while day.weekday() != int(s.deposit_weekday):
            day += timedelta(days=1)
    else:
        day = close + timedelta(days=int(s.deposit_days))
    for _ in range(_MAX_ROLL_DAYS):
        if day.weekday() in s.weekend or (s.skip_holidays and day in holidays):
            day += timedelta(days=1)
            continue
        return day
    raise ScheduleInvalid('لا يوجد يوم إيداع خلال 60 يومًا — راجع العطلة والإجازات')


def deposit_for_sale(s: Schedule, sale_day: date, holidays: FrozenSet[date] = frozenset()) -> date:
    return deposit_day(s, batch_close(s, sale_day), holidays)


# ── what is due ──────────────────────────────────────────────────────────────

def due_deposits(
    s: Schedule,
    open_payments: Sequence[Tuple[int, date, float]],
    as_of: date,
    net_of: Callable[[float, int], float],
    holidays: FrozenSet[date] = frozenset(),
) -> List[Due]:
    """The deposits that have reached the bank by *as_of*, oldest first.

    *open_payments*: (invoice_payment_id, sale day, open amount). *net_of*
    (gross, count) is what reaches the bank -- gross less commission and its
    VAT, the settlement's own computation. A batch whose deposit day is after
    *as_of* is not due, nor any after it. Under a minimum, batches whose net
    together falls short are held and join the next deposit.
    """
    batches: dict = {}
    for ip_id, sale_day, amount in open_payments:
        if amount <= 0.005:
            continue
        batches.setdefault(batch_close(s, sale_day), []).append((ip_id, sale_day, round(float(amount), 2)))

    dues: List[Due] = []
    held: List[Tuple[int, date, float]] = []
    for close in sorted(batches):
        deposit = deposit_day(s, close, holidays)
        if deposit > as_of:
            break
        group = held + sorted(batches[close], key=lambda p: (p[1], p[0]))
        gross = round(sum(a for _, _, a in group), 2)
        if s.min_net > 0.005 and net_of(gross, len(group)) < s.min_net - 0.005:
            held = group
            continue
        dues.append(Due(close_date=close, deposit_date=deposit,
                        first_sale_day=min(d for _, d, _ in group),
                        payments=[(i, a) for i, _, a in group]))
        held = []
    return dues


# ── words, for the screens ───────────────────────────────────────────────────

def describe(s: Schedule) -> str:
    """The schedule in one Arabic line (the settings and clearing screens)."""
    if s.period == 'weekly':
        parts = [f'دفعة أسبوعية تُقفل نهاية {WEEKDAYS_AR[int(s.close_weekday)]}']
    else:
        parts = ['دفعة يومية تُقفل منتصف الليل']
    if s.deposit_rule == 'weekday':
        parts.append(f'تُودَع {WEEKDAYS_AR[int(s.deposit_weekday)]} التالي')
    elif s.deposit_days == 0:
        parts.append('تُودَع في اليوم نفسه')
    elif s.deposit_days == 1:
        parts.append('تُودَع بعد يوم واحد')
    else:
        parts.append(f'تُودَع بعد {s.deposit_days} أيام')
    if s.weekend:
        parts.append('لا إيداع ' + ' و'.join(WEEKDAYS_AR[d] for d in sorted(s.weekend)))
    if s.skip_holidays:
        parts.append('ولا في الإجازات الرسمية')
    parts.append(f'خطة مرنة: حدّ أدنى {s.min_net:,.2f} صافيًا، وما دونه يُرحَّل' if s.min_net > 0.005
                 else 'خطة ثابتة: بلا حدّ أدنى')
    return ' · '.join(parts)


def preview(s: Schedule, first_sale_day: date, days: int = 14,
            holidays: FrozenSet[date] = frozenset()) -> list:
    """Sale day -> its batch's close and deposit day, for *days* days."""
    out = []
    for n in range(days):
        sale = first_sale_day + timedelta(days=n)
        close = batch_close(s, sale)
        out.append({
            'sale_day': sale.isoformat(), 'sale_weekday': WEEKDAYS_AR[sale.weekday()],
            'close_day': close.isoformat(),
            'deposit_day': (dep := deposit_day(s, close, holidays)).isoformat(),
            'deposit_weekday': WEEKDAYS_AR[dep.weekday()],
        })
    return out
