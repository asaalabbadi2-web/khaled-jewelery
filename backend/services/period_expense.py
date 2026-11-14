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
MONTH_ENTRY, RECLASS_ENTRY = 'period_expense', 'period_expense_reclass'     # law 6's keys


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
    """What the schedule has accrued by *day* (or before it), in halalas: the
    months over, and what a new year's database carried. A cancelled expense
    accrues nothing -- what was posted for it is taken back (law 7)."""
    carried = halalas(pe.accrued_before_opening or 0)
    if getattr(pe, 'status', 'active') == 'cancelled':
        return carried
    return carried + sum(m.amount for m in _months(pe) if (m.ends < day if before else m.ends <= day))


def _day_of(value):
    return value.date() if hasattr(value, 'date') else value


def _payments(pe):
    """(date, voucher id, halalas, the day it stopped counting or None) of the
    vouchers' lines on *pe* that were ever posted: an approved voucher counts
    from its date; a cancelled one from its date until the day it was
    cancelled, its reversal's day -- so the paid at a past date is what the
    books said then."""
    from models import Voucher, VoucherAccountLine, db
    rows = (db.session.query(Voucher.date, Voucher.id, VoucherAccountLine.amount, Voucher.status,
                             Voucher.cancelled_at, Voucher.journal_entry_id)
            .join(VoucherAccountLine, VoucherAccountLine.voucher_id == Voucher.id)
            .filter(VoucherAccountLine.period_expense_id == pe.id,
                    Voucher.status.in_(('approved', 'cancelled')))
            .all())
    out = []
    for d, vid, amount, status, cancelled_at, entry_id in rows:
        if status == 'cancelled' and not (entry_id and cancelled_at):
            continue                                  # cancelled before it was approved: never paid
        out.append((_day_of(d), vid, halalas(amount), _day_of(cancelled_at) if status == 'cancelled' else None))
    return out


def _counts(day, stopped, at: date) -> bool:
    return day <= at and (stopped is None or stopped > at)


def paid_to(pe, day: date, *, before_voucher=None) -> int:
    """What *pe* was paid by *day*. With *before_voucher* (its date and id),
    only the payments before it: an earlier day, or the same day and a lower id."""
    carried = halalas(pe.paid_before_opening or 0)
    if before_voucher is None:
        return carried + sum(h for d, _, h, stopped in _payments(pe) if _counts(d, stopped, day))
    v_day, v_id = before_voucher
    return carried + sum(h for d, vid, h, stopped in _payments(pe)
                         if vid != v_id and (d < v_day or (d == v_day and vid < v_id))
                         and (stopped is None or stopped > v_day))


def posted_accrual(pe, *, through: date | None = None, before: date | None = None) -> int:
    """What its month entries have accrued in the books (law 6), in halalas:
    the expense's debits less its credits on the entries keyed to it, posted;
    with what a new year's database carried."""
    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    q = (db.session.query(db.func.coalesce(db.func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit), 0))
         .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(*counted_line_filters(), JournalEntry.reference_type == MONTH_ENTRY,
                 JournalEntry.reference_id == pe.id, JournalEntryLine.account_id == pe.expense_account_id))
    if through is not None:
        q = q.filter(db.func.date(JournalEntry.date) <= through)
    if before is not None:
        q = q.filter(db.func.date(JournalEntry.date) < before)
    return halalas(pe.accrued_before_opening or 0) + halalas(q.scalar() or 0)


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
    # The balance as the books hold it: paid less what the month entries have
    # posted -- not the schedule, or a payment would settle an accrual the
    # books do not carry yet (law 4; the schedule is law 8's measure).
    balance = before - posted_accrual(pe, before=voucher_day)
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


def _paid_now(pe, voucher_id=None) -> int:
    """What the approved vouchers have paid, all told (not a cancelled one)."""
    return halalas(pe.paid_before_opening or 0) + sum(
        h for _, vid, h, stopped in _payments(pe) if stopped is None and (voucher_id is None or vid != voucher_id))


def check_payments_fit(paying: dict, *, voucher_id=None):
    """When a voucher is saved (law 2): what it pays on each expense ({pe: riyals})
    fits beside the approved payments of the others, and the two accounts are
    mapped -- refused now, by name, not left for its posting to fail."""
    _accounts()
    for pe, amount in paying.items():
        others = _paid_now(pe, voucher_id)
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
        'as_of': day.isoformat(), **values(pe, day), 'posted_accrued': riyals(posted_accrual(pe, through=day)),
        'schedule': [{'month': m.month.isoformat()[:7], 'amount': riyals(m.amount)}
                     for m in schedule(pe.amount, pe.period_start, pe.period_end)],
    }


# ── laws 6 and 7: the month's entry, one rule ────────────────────────────────
#
# A month's entry is what the schedule has accrued by the month's end less
# what the books have posted before it. That one rule is law 6 and law 7: a
# month not written, an edit of the amount or the period, a cancellation, a
# closed month -- each is a difference the first open month's entry takes,
# whole (the owner's cumulative catch-up, option A). No posted entry is
# changed; a closed month is not written (law 9).

def _month_split(pe, amount: int, month_end: date, prepaid_id: int, accrued_id: int):
    """The credit side of a month's entry of *amount* halalas (law 4, the other
    way): from a prepaid balance first, the rest accrued. A negative amount
    (an accrual taken back) debits them: accrued first, the rest prepaid."""
    balance = paid_to(pe, month_end) - posted_accrual(pe, through=month_end)
    if amount > 0:
        from_prepaid = min(amount, max(0, balance))
        return [(prepaid_id, 0, from_prepaid), (accrued_id, 0, amount - from_prepaid)]
    back = -amount
    to_accrued = min(back, max(0, -balance))
    return [(accrued_id, to_accrued, 0), (prepaid_id, back - to_accrued, 0)]


def _keyed(reference_type, reference_id, month: date):
    from models import JournalEntry
    return JournalEntry.query.filter_by(reference_type=reference_type, reference_id=reference_id,
                                        reference_number=month.isoformat()[:7], is_deleted=False).first()


def _write(*, reference_type, reference_id, month_end: date, description, lines, by, now):
    """One entry, posted, dated the month's last day; lines (account, debit, credit) in halalas."""
    from datetime import datetime as _dt
    from accounting.reference_number_service import generate_journal_entry_number
    from models import JournalEntry, JournalEntryLine, db
    when = _dt.combine(month_end, _dt.min.time())
    entry = JournalEntry(entry_number=generate_journal_entry_number('JE', when), date=when,
                         description=description, entry_type='استحقاق مصروف فترة',
                         reference_type=reference_type, reference_id=reference_id,
                         reference_number=month_end.isoformat()[:7], created_by=by,
                         is_posted=True, posted_at=now, posted_by=by)
    db.session.add(entry)
    db.session.flush()
    for account_id, debit, credit in lines:
        if debit or credit:
            db.session.add(JournalEntryLine(journal_entry_id=entry.id, account_id=account_id,
                                            cash_debit=riyals(debit), cash_credit=riyals(credit),
                                            description=description))
    db.session.flush()
    return entry


def _ledger_balance(account_id: int, through: date) -> int:
    """An account's debit balance in the books by *through*, in halalas."""
    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    total = (db.session.query(db.func.coalesce(db.func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit), 0))
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters(), JournalEntryLine.account_id == account_id,
                     db.func.date(JournalEntry.date) <= through).scalar())
    return halalas(total or 0)


def _month_ends(start: date, through: date):
    month = start.replace(day=1)
    while _month_end(month) <= through:
        yield _month_end(month)
        month = _next_month(month)


def accrue(through: date, *, by: str, now, dry_run: bool = True) -> dict:
    """The month entries due by *through* -- the authorised month-end action
    (law 6): previewed (dry_run, the default: written in a savepoint and rolled
    back, so the figures are the ones it would write), then applied. For each
    month over by *through* and open (after the lock), each expense's entry by
    the one rule; then, the month's entries made, the two accounts reclassified
    if the expenses' balances say the sum is right but its split is not (a
    payment cancelled after installments). A drift of the sum is reported, not
    written over (law 8)."""
    from models import PeriodExpense, db
    from period_lock_guard import closed_through
    prepaid_id, accrued_id = _accounts()
    closed = closed_through(db.session.connection())
    expenses = PeriodExpense.query.order_by(PeriodExpense.id).all()
    plan = {'through': through.isoformat(), 'closed_through': closed.isoformat() if closed else None,
            'entries': [], 'reclass': [], 'drift': []}
    if not expenses:
        return plan
    savepoint = db.session.begin_nested()
    start = min(pe.period_start for pe in expenses)
    for month_end in _month_ends(start, through):
        if closed is not None and month_end <= closed:
            continue                                   # a closed month: its share goes to the first open one
        for pe in expenses:
            if month_end < pe.period_start.replace(day=1) or _keyed(MONTH_ENTRY, pe.id, month_end):
                continue
            amount = accrued_to(pe, month_end) - posted_accrual(pe, through=month_end)
            if amount == 0:
                continue
            scheduled = next((m.amount for m in _months(pe) if m.ends == month_end), 0)
            label = f'{pe.description} — {month_end.isoformat()[:7]}'
            if amount != scheduled:
                label += f' (تسوية تراكمية: المجدول {riyals(scheduled):,.2f})'
            credits = _month_split(pe, amount, month_end, prepaid_id, accrued_id)
            expense_line = (pe.expense_account_id, amount, 0) if amount > 0 else (pe.expense_account_id, 0, -amount)
            _write(reference_type=MONTH_ENTRY, reference_id=pe.id, month_end=month_end, description=label,
                   lines=[expense_line, *credits], by=by, now=now)
            plan['entries'].append({'period_expense_id': pe.id, 'month': month_end.isoformat()[:7],
                                    'amount': riyals(amount), 'scheduled': riyals(scheduled)})
        _reclassify(expenses, month_end, prepaid_id, accrued_id, plan, by=by, now=now)
    db.session.flush()
    if dry_run:
        savepoint.rollback()
    else:
        savepoint.commit()
    return plan


def _reclassify(expenses, month_end: date, prepaid_id: int, accrued_id: int, plan: dict, *, by, now):
    balances = [paid_to(pe, month_end) - posted_accrual(pe, through=month_end) for pe in expenses]
    want_prepaid = sum(b for b in balances if b > 0)
    want_net = sum(balances)
    held_prepaid, held_accrued = _ledger_balance(prepaid_id, month_end), _ledger_balance(accrued_id, month_end)
    if held_prepaid + held_accrued != want_net:
        plan['drift'].append({'month': month_end.isoformat()[:7], 'books': riyals(held_prepaid + held_accrued),
                              'expenses': riyals(want_net)})
        return
    move = want_prepaid - held_prepaid
    if move == 0 or _keyed(RECLASS_ENTRY, int(month_end.strftime('%Y%m')), month_end):
        return
    lines = [(prepaid_id, move, 0), (accrued_id, 0, move)] if move > 0 else [(accrued_id, -move, 0), (prepaid_id, 0, -move)]
    _write(reference_type=RECLASS_ENTRY, reference_id=int(month_end.strftime('%Y%m')), month_end=month_end,
           description=f'إعادة تصنيف مصروفات الفترات — {month_end.isoformat()[:7]}', lines=lines, by=by, now=now)
    plan['reclass'].append({'month': month_end.isoformat()[:7], 'to_prepaid': riyals(move)})


# ── law 7: an edit, a cancellation -- recorded, never a posted entry changed ──

def _revise(pe, *, reason: str, by: str, now, **changes):
    import json
    from models import PeriodExpenseRevision, db
    reason = (reason or '').strip()
    if not reason:
        raise PeriodExpenseRefused('reason_required', 'اذكر سبب التعديل: يُحفظ في سجلّ المصروف.')
    before = {k: str(getattr(pe, k)) for k in changes}
    for k, v in changes.items():
        setattr(pe, k, v)
    db.session.add(PeriodExpenseRevision(period_expense_id=pe.id, reason=reason, changed_by=by or 'system',
                                         changed_at=now, before=json.dumps(before, ensure_ascii=False),
                                         after=json.dumps({k: str(v) for k, v in changes.items()}, ensure_ascii=False)))
    db.session.flush()


def edit(pe, *, reason: str, by: str, now, amount=None, period_start: date | None = None,
         period_end: date | None = None):
    """A new amount or period (law 7). The posted months stay; the next month
    entry takes the whole difference."""
    if pe.status != 'active':
        raise PeriodExpenseRefused('period_expense_cancelled', 'المصروف ملغى.')
    changes = {}
    if amount is not None:
        if halalas(amount) <= 0:
            raise PeriodExpenseRefused('amount_not_positive', 'المبلغ أكبر من صفر.')
        if halalas(amount) < _paid_now(pe):
            raise PeriodExpenseRefused('amount_below_paid',
                                       f'المدفوع {riyals(_paid_now(pe)):,.2f} أكثر من المبلغ الجديد.')
        changes['amount'] = riyals(halalas(amount))
    if period_start is not None or period_end is not None:
        start, end = period_start or pe.period_start, period_end or pe.period_end
        schedule(changes.get('amount', pe.amount), start, end)
        changes['period_start'], changes['period_end'] = start, end
    if not changes:
        raise PeriodExpenseRefused('unchanged', 'لا تعديل.')
    _revise(pe, reason=reason, by=by, now=now, **changes)
    return pe


def cancel(pe, *, reason: str, by: str, now):
    """Cancelled: it accrues nothing more, and the next month entry takes back
    what was posted (law 7). Refused while a payment stands on it -- cancel
    the payment, or edit the expense to what it really cost."""
    if pe.status == 'cancelled':
        raise PeriodExpenseRefused('unchanged', 'المصروف ملغى أصلًا.')
    if _paid_now(pe) > 0:
        raise PeriodExpenseRefused('cancel_with_payments',
                                   'على المصروف دفعات قائمة: ألغِ سنداتها، أو عدّل المصروف إلى كلفته الحقيقية.')
    _revise(pe, reason=reason, by=by, now=now, status='cancelled')
    return pe


# ── law 8: the ledger against the expenses -- reported, never repaired ────────

FAR = date(9999, 12, 31)


def ledger_against_expenses() -> list[dict]:
    """The two accounts in the ledger against the expenses' balances as the
    books hold them (paid less posted), each; none while the roles are unmapped."""
    from models import PeriodExpense
    try:
        prepaid_id, accrued_id = _accounts()
    except PeriodExpenseRefused:
        return []
    balances = [paid_to(pe, FAR) - posted_accrual(pe, through=FAR) for pe in PeriodExpense.query.all()]
    return [
        {'account_id': prepaid_id, 'role': PREPAID, 'ledger': riyals(_ledger_balance(prepaid_id, FAR)),
         'expenses': riyals(sum(b for b in balances if b > 0))},
        {'account_id': accrued_id, 'role': ACCRUED, 'ledger': riyals(_ledger_balance(accrued_id, FAR)),
         'expenses': riyals(sum(b for b in balances if b < 0))},
    ]


def books_today():
    """The books' own today: their last posted entry's day -- the months
    before its month are over by what the books say, not by a clock."""
    from models import JournalEntry, db
    last = (db.session.query(db.func.max(JournalEntry.date))
            .filter(JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False)).scalar())
    return _day_of(last) if last else None


def months_behind(through: date | None = None, *, expenses=None) -> list[dict]:
    """The period expenses whose months over by *through* (default: the last
    month before the books' today) are not all posted: the schedule's
    accrued by then less what the month entries posted."""
    from models import PeriodExpense
    if through is None:
        today = books_today()
        if today is None:
            return []
        through = date.fromordinal(today.replace(day=1).toordinal() - 1)   # the month before the books' today, its last day
    out = []
    for pe in (expenses if expenses is not None else PeriodExpense.query.order_by(PeriodExpense.id).all()):
        behind = accrued_to(pe, through) - posted_accrual(pe, through=through)
        if behind != 0:
            ended = [m.month.isoformat()[:7] for m in _months(pe) if m.ends <= through]
            out.append({'period_expense_id': pe.id, 'description': pe.description, 'through': through.isoformat(),
                        'behind': riyals(behind), 'months_over': len(ended)})
    return out
