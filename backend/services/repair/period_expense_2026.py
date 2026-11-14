"""2026's expenses of a period, put in their months (ADR-090, phase 8).

The owner's figures (services/repair/period_expense_2026.json): the rent and
the licences, each a period expense of 2026, each voucher already paid a
payment on it. Until now each was booked whole on its voucher's day: the rent
of January to June took 72,450 from June alone.

For each expense: the period expense made; its vouchers' expense lines linked
to it (law 2). Then in time order, month by month through *through*:

  - each voucher of the month: a correction dated the voucher's own day --
    the expense account credited what the voucher debited, and the payment's
    debit put where the expense's balance stands that day (law 4): what pays
    off the months accrued before it to «مصروفات مستحقة», the rest to
    «مصروفات مقدَّمة». The voucher's own entry stays as it is (no posted entry
    is changed); the two net to nothing on the expense that day;
  - then the month's entries, by the one rule (law 6, services.period_expense.accrue).

Each split reads the paid and the posted as of its own date, not what was
written before it, so the order of writing changes nothing (tried: the months
first, then the corrections, wrote the same); in time order the run reads as
the year went. No reclassification is expected.

Refused, writing nothing (PlanRefused): an account whose number names
another; a voucher not approved, not a payment, or whose debit on the account
is not the figure; a voucher already linked; the two accounts not mapped; a
month already closed by the lock. A second run finds the expenses made and
writes nothing. The dry run (the default) is the same run in a savepoint,
rolled back: the figures it shows are the ones it would write, with each
month's expense on the plan's accounts and the weight profit's layer ④,
before and after.
"""
from __future__ import annotations

import datetime as dt
import os

from models import Account, PeriodExpense, Voucher, VoucherAccountLine, db
from services.repair.planned_entries import PlanRefused, load, norm

FIGURES = os.path.join(os.path.dirname(__file__), 'period_expense_2026.json')
BY = 'period_expense_2026'
PAYMENT_CORRECTION = 'period_expense_payment'


def _account(spec) -> Account:
    acc = Account.query.filter_by(account_number=str(spec['number'])).first()
    if acc is None or norm(acc.name) != norm(spec['name']):
        raise PlanRefused(f"الحساب {spec['number']}: ليس «{spec['name']}»"
                          + (f" بل «{acc.name}»" if acc is not None else ' — غير موجود'))
    return acc


def _voucher_line(spec, account: Account):
    """The voucher, and its one cash debit line on *account* -- as the plan found it."""
    voucher = Voucher.query.filter_by(voucher_number=spec['number']).first()
    if voucher is None:
        raise PlanRefused(f"السند {spec['number']} غير موجود")
    if voucher.status != 'approved' or (voucher.voucher_type or '').lower() != 'payment':
        raise PlanRefused(f"السند {spec['number']}: {voucher.status} {voucher.voucher_type}، لا سند صرف معتمد")
    debits = VoucherAccountLine.query.filter_by(voucher_id=voucher.id, account_id=account.id,
                                                line_type='debit', amount_type='cash').all()
    if len(debits) != 1 or abs(float(debits[0].amount) - float(spec['amount'])) > 0.005:
        raise PlanRefused(f"السند {spec['number']}: مدينه على {account.account_number} "
                          f"{[float(l.amount) for l in debits]} لا {spec['amount']}")
    if debits[0].period_expense_id is not None:
        raise PlanRefused(f"السند {spec['number']}: مربوط بمصروف فترة أصلًا")
    return voucher, debits[0]


def _month_ends(start: dt.date, through: dt.date):
    month = start.replace(day=1)
    while True:
        end = (month.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
        if end > through:
            return
        yield end
        month = end + dt.timedelta(days=1)


def _monthly(accounts: set, start: dt.date, through: dt.date) -> dict:
    """Each month's expense on the plan's accounts, and its weight profit's layer ④ and whole."""
    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine
    from services.weight_position import performance_by_month
    month = db.func.to_char(JournalEntry.date, 'YYYY-MM')
    rows = (db.session.query(month, db.func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(accounts),
                    db.func.date(JournalEntry.date) >= start, db.func.date(JournalEntry.date) <= through)
            .group_by(month).all())
    expense = {m: round(float(v or 0), 2) for m, v in rows}
    weight = {r['month']: (r['layers'].get('expense_cash', 0.0), r['weight_profit'])
              for r in performance_by_month(start, through)}
    months = sorted(set(expense) | {m for m in weight if m <= through.isoformat()[:7]})
    return {m: {'expense': expense.get(m, 0.0), 'layer4': weight.get(m, (0.0, 0.0))[0],
                'weight_profit': weight.get(m, (0.0, 0.0))[1]} for m in months}


def apply(*, through: dt.date, by: str, now: dt.datetime, dry_run: bool = True, figures: dict | None = None) -> dict:
    """The plan through *through* (a month's last day). Flushes; the caller commits."""
    from period_lock_guard import closed_through
    from services.period_expense import _accounts, accrue, create, payment_debits
    from services.repair.entries import write_entry
    figures = figures or load(FIGURES)
    specs = figures['expenses']
    if PeriodExpense.query.filter_by(created_by=by).count():
        return {'applied': False, 'already': True, 'message': 'مصروفات 2026 مُنشأة أصلًا: لا شيء يُكتب'}
    _accounts()                                         # the two roles mapped, or refused by name
    closed = closed_through(db.session.connection())
    first = min(dt.date.fromisoformat(s['start']) for s in specs)
    if closed is not None and closed >= first:
        raise PlanRefused(f'الدفاتر مقفلة حتى {closed}: الأداة تكتب من {first} — تُشغَّل قبل الإقفال')

    plan = {'through': through.isoformat(), 'expenses': [], 'corrections': [], 'months': [], 'reclass': [],
            'drift': []}
    resolved = []
    for spec in specs:                                  # every refusal before anything is written
        account = _account(spec['account'])
        lines = [_voucher_line(v, account) for v in spec['vouchers']]
        if sum(float(v['amount']) for v in spec['vouchers']) > float(spec['amount']) + 0.005:
            raise PlanRefused(f"{spec['key']}: سنداته أكثر من مبلغه")
        resolved.append((spec, account, lines))
    accounts = {account.id for _, account, _ in resolved}
    start = min(dt.date.fromisoformat(s['start']) for s in specs)
    before = _monthly(accounts, start, through)

    savepoint = db.session.begin_nested()
    payments = []                                       # (voucher day, voucher, line, expense)
    for spec, account, lines in resolved:
        pe = create(description=spec['description'], expense_account_id=account.id, amount=spec['amount'],
                    period_start=dt.date.fromisoformat(spec['start']), period_end=dt.date.fromisoformat(spec['end']),
                    by=by, now=now)
        for voucher, line in lines:
            line.period_expense_id = pe.id
            payments.append((voucher.date.date(), voucher, line, pe))
        plan['expenses'].append({'key': spec['key'], 'id': pe.id, 'amount': spec['amount'],
                                 'vouchers': [v.voucher_number for v, _ in lines]})
    db.session.flush()

    for month_end in _month_ends(start, through):
        month_start = month_end.replace(day=1)
        for day, voucher, line, pe in sorted(payments, key=lambda p: (p[0], p[1].id)):
            if not (month_start <= day <= month_end):
                continue
            debits = payment_debits(pe, line.amount, voucher_day=day, voucher_id=voucher.id)
            entry = write_entry(
                date=voucher.date, reference_type=PAYMENT_CORRECTION, reference_id=voucher.id,
                reference_number=voucher.voucher_number, by=by, now=now,
                description=f'{pe.description}: سند {voucher.voucher_number} دفعة على مصروف الفترة، لا مصروف كله يومه',
                lines=[{'account_id': pe.expense_account_id, 'cash_credit': float(line.amount),
                        'description': f'من مصروف يوم السند {voucher.voucher_number}'},
                       *[{'account_id': acc, 'cash_debit': amt, 'description': pe.description} for acc, amt in debits]])
            plan['corrections'].append({'voucher': voucher.voucher_number, 'date': day.isoformat(),
                                        'entry': entry.entry_number,
                                        'debits': [{'account_id': a, 'amount': x} for a, x in debits]})
        run = accrue(month_end, by=by, now=now, dry_run=False)
        plan['months'].append({'month': month_end.isoformat()[:7],
                               'entries': sum(1 for e in run['entries'] if e['month'] == month_end.isoformat()[:7]),
                               'amount': round(sum(e['amount'] for e in run['entries']
                                                   if e['month'] == month_end.isoformat()[:7]), 2)})
        plan['drift'] += run['drift']          # in time order none is expected, nor a reclass
        plan['reclass'] += run['reclass']
    db.session.flush()
    after = _monthly(accounts, start, through)
    plan['before_after'] = [{'month': m, 'before': before.get(m), 'after': after.get(m)}
                            for m in sorted(set(before) | set(after))]
    if dry_run:
        savepoint.rollback()
    else:
        savepoint.commit()
    plan['applied'] = not dry_run
    return plan
