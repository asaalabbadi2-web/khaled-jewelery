"""An expense of a period, accrued month by month; its vouchers its payments (ADR-090).

A PeriodExpense is the cost of a period -- an account, an amount net of VAT,
from and to. A voucher's cash debit line may name it: that line is a payment
on it. Three values, at any date, all derived (law 3):

    accrued  the schedule's months over by then (law 5);
    paid     the approved vouchers' lines on it, dated by then;
    balance  paid - accrued: above zero a prepaid expense (an asset), below
             zero an accrued one (a liability). Not an account, not stored --
             reconciled with the ledger's two accounts (law 8, phase 6).

The schedule (law 5, a law, not a setting): whole months equal; a part month
by its days; in halalas; the last month takes the rounding, so the months add
to the amount exactly.

A payment's debit (law 4) goes where the balance stands before it: what it
pays of an accrued balance to the accrued account, the rest to the prepaid one
-- a payment crossing zero is two lines. A month's accrual (phase 4) the other
way. A payment beyond the amount is refused (overpaid_period_expense).

Order within a day: a month's accrual is dated its last day and follows that
day's payments; payments among themselves by their voucher's id.
"""
from __future__ import annotations

import calendar
import math
from dataclasses import dataclass
from datetime import date
from fractions import Fraction

PREPAID, ACCRUED = 'prepaid_expenses', 'accrued_expenses'


class PeriodExpenseRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def halalas(value) -> int:
    """Riyals to halalas, half up."""
    return math.floor(Fraction(str(value)) * 100 + Fraction(1, 2)) if value is not None else 0


def riyals(h: int) -> float:
    return round(h / 100, 2)


def _month_end(day: date) -> date:
    return day.replace(day=calendar.monthrange(day.year, day.month)[1])


def _next_month(day: date) -> date:
    return date(day.year + (day.month == 12), day.month % 12 + 1, 1)


# ── law 5: the schedule ────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Month:
    month: date          # its first day
    ends: date           # its last day: the accrual's date
    amount: int          # halalas


def schedule(amount, start: date, end: date) -> list[Month]:
    """The months of a period and each one's share (law 5)."""
    if end < start:
        raise PeriodExpenseRefused('period_reversed', 'نهاية الفترة قبل بدايتها.')
    total = halalas(amount)
    parts = []                                       # (first day, weight as a fraction of a month)
    month = start.replace(day=1)
    while month <= end:
        days_in = calendar.monthrange(month.year, month.month)[1]
        first, last = max(start, month), min(end, _month_end(month))
        days = (last - first).days + 1
        parts.append((month, Fraction(1) if days == days_in else Fraction(days, days_in)))
        month = _next_month(month)
    weight = sum(w for _, w in parts)
    out, given = [], 0
    for i, (month, w) in enumerate(parts):
        share = total - given if i == len(parts) - 1 else math.floor(Fraction(total) * w / weight + Fraction(1, 2))
        given += share
        out.append(Month(month, _month_end(month), share))
    return out


# ── law 3: the three values ───────────────────────────────────────────────────

def _months(pe) -> list[Month]:
    months = schedule(pe.amount, pe.period_start, pe.period_end)
    if pe.opened_on:                                 # law 12: what came before the opening, carried
        months = [m for m in months if m.ends >= pe.opened_on]
    return months


def accrued_to(pe, day: date, *, before: bool = False) -> int:
    """The months over by *day* (or before it), in halalas."""
    carried = halalas(pe.accrued_before_opening or 0)
    return carried + sum(m.amount for m in _months(pe) if (m.ends < day if before else m.ends <= day))


def _payments(pe):
    """(date, voucher id, halalas) of the approved vouchers' lines on *pe*."""
    from models import Voucher, VoucherAccountLine, db
    rows = (db.session.query(Voucher.date, Voucher.id, VoucherAccountLine.amount)
            .join(VoucherAccountLine, VoucherAccountLine.voucher_id == Voucher.id)
            .filter(VoucherAccountLine.period_expense_id == pe.id, Voucher.status == 'approved')
            .all())
    return [(d.date() if hasattr(d, 'date') else d, vid, halalas(a)) for d, vid, a in rows]


def paid_to(pe, day: date, *, before_voucher=None) -> int:
    """What the approved vouchers paid on *pe* by *day*. With *before_voucher*
    (its date and id), only those before it: same day, a lower id."""
    carried = halalas(pe.paid_before_opening or 0)
    if before_voucher is None:
        return carried + sum(h for d, _, h in _payments(pe) if d <= day)
    v_day, v_id = before_voucher
    return carried + sum(h for d, vid, h in _payments(pe)
                         if vid != v_id and (d < v_day or (d == v_day and vid < v_id)))


def values(pe, day: date) -> dict:
    accrued, paid = accrued_to(pe, day), paid_to(pe, day)
    balance = paid - accrued
    return {'accrued': riyals(accrued), 'paid': riyals(paid), 'balance': riyals(balance),
            'standing': 'prepaid' if balance > 0 else 'accrued' if balance < 0 else 'settled',
            'amount': riyals(halalas(pe.amount)), 'remaining_to_pay': riyals(halalas(pe.amount) - paid)}


# ── law 4: where a payment's debit goes ───────────────────────────────────────

def _accounts():
    from accounting.chart_tree import role_account_id
    from accounting.mappings import AccountNotMapped
    try:
        return role_account_id(PREPAID), role_account_id(ACCRUED)
    except AccountNotMapped:
        raise PeriodExpenseRefused('period_expense_accounts_not_mapped',
                                   'حسابا «مصروفات مقدَّمة» و«مصروفات مستحقة» غير مربوطين في الربط المحاسبي.')


def payment_debits(pe, amount, *, voucher_day: date, voucher_id: int) -> list[tuple[int, float]]:
    """The debit lines of a payment of *amount* on *pe* (law 4): [(account id, riyals)]."""
    pay = halalas(amount)
    before = paid_to(pe, voucher_day, before_voucher=(voucher_day, voucher_id))
    if before + pay > halalas(pe.amount):
        raise PeriodExpenseRefused(
            'overpaid_period_expense',
            f'«{pe.description}»: المدفوع {riyals(before + pay):,.2f} يتجاوز المبلغ {riyals(halalas(pe.amount)):,.2f}.')
    prepaid_id, accrued_id = _accounts()
    balance = before - accrued_to(pe, voucher_day, before=True)
    settles = min(pay, max(0, -balance))           # what it pays of an accrued balance
    lines = [(accrued_id, riyals(settles)), (prepaid_id, riyals(pay - settles))]
    return [(acc, amt) for acc, amt in lines if amt > 0]


def check_payment_line(pe_id, *, voucher_type: str, amount_type: str, line_type: str, account_id) -> object:
    """A voucher line naming a period expense, checked when the voucher is
    saved (law 2): a payment's cash debit, on the expense's own account, of an
    expense standing. Returns the expense."""
    from models import PeriodExpense, db
    pe = db.session.get(PeriodExpense, int(pe_id))
    if pe is None or pe.status != 'active':
        raise PeriodExpenseRefused('period_expense_not_found', 'مصروف الفترة غير موجود أو ملغى.')
    if (voucher_type or '').lower() != 'payment' or amount_type != 'cash' or line_type != 'debit':
        raise PeriodExpenseRefused('period_expense_line',
                                   'مصروف الفترة يُدفع بسطر صرف نقدي مدين في سند صرف.')
    if int(account_id) != int(pe.expense_account_id):
        raise PeriodExpenseRefused('period_expense_account',
                                   f'سطر «{pe.description}» يكون على حساب مصروفه نفسه.')
    return pe


def check_payments_fit(paying: dict, *, voucher_id=None):
    """When a voucher is saved (law 2): what it pays on each expense ({pe: riyals})
    fits beside the approved payments of the others, and the two accounts are
    mapped -- refused now, by name, not left for its posting to fail."""
    _accounts()
    for pe, amount in paying.items():
        others = halalas(pe.paid_before_opening or 0) + sum(
            h for _, vid, h in _payments(pe) if voucher_id is None or vid != voucher_id)
        if others + halalas(amount) > halalas(pe.amount):
            raise PeriodExpenseRefused(
                'overpaid_period_expense',
                f'«{pe.description}»: المدفوع {riyals(others + halalas(amount)):,.2f} '
                f'يتجاوز المبلغ {riyals(halalas(pe.amount)):,.2f}.')


# ── the expense itself ────────────────────────────────────────────────────────

def create(*, description: str, expense_account_id: int, amount, period_start: date, period_end: date,
           by: str, now) -> object:
    """A new period expense (law 1). Flushes; the caller commits."""
    from models import Account, PeriodExpense, db
    description = (description or '').strip()
    if not description:
        raise PeriodExpenseRefused('description_required', 'اكتب وصف المصروف.')
    if halalas(amount) <= 0:
        raise PeriodExpenseRefused('amount_not_positive', 'المبلغ أكبر من صفر.')
    schedule(amount, period_start, period_end)       # refuses a reversed period
    account = db.session.get(Account, int(expense_account_id)) if expense_account_id else None
    if account is None or (account.type or '').lower() != 'expense' or account.is_active is False:
        raise PeriodExpenseRefused('not_an_expense_account', 'اختر حساب مصروف قائمًا.')
    if account.tracks_weight:
        raise PeriodExpenseRefused('not_an_expense_account', 'مصروف الفترة نقدي: اختر حساب المصروف لا توأمه الوزني.')
    pe = PeriodExpense(description=description, expense_account_id=account.id, amount=riyals(halalas(amount)),
                       period_start=period_start, period_end=period_end, status='active',
                       created_by=by or 'system', created_at=now)
    db.session.add(pe)
    db.session.flush()
    return pe


def to_dict(pe, day: date) -> dict:
    return {
        'id': pe.id, 'description': pe.description, 'expense_account_id': pe.expense_account_id,
        'amount': riyals(halalas(pe.amount)), 'period_start': pe.period_start.isoformat(),
        'period_end': pe.period_end.isoformat(), 'status': pe.status,
        'as_of': day.isoformat(), **values(pe, day),
        'schedule': [{'month': m.month.isoformat()[:7], 'amount': riyals(m.amount)}
                     for m in schedule(pe.amount, pe.period_start, pe.period_end)],
    }
