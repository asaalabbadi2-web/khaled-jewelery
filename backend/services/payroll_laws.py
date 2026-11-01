"""A month's salary kept whole: approved with its accrual, paid by its voucher (PAYROLL-1).

The owner, 1 Nov 2026 («ابدأ» to the payroll plan's first stage). On the 31 Oct
copy fifteen salaries (December-February, 122,500) were «paid» with no accrual,
and the routes let more through: amounts edited after their accrual was posted,
a bulk approval that kept «approved» when its accrual failed, a cancellation
that left its accrual standing. The laws, asked by every route that writes a
payroll entry (tests/test_payroll_is_kept_whole.py):

  1. the amounts, the employee and the month are edited while pending alone;
  2. «paid» is the payment's to set (mark-paid writes its voucher);
  3. the net is basic + allowances - deductions, the server's; the month is
     1-12 of a four-digit year;
  4. approving is its accrual -- when it cannot be written, the entry stays pending;
  5. only an approved entry is paid, its accrual written first if it has none;
  6. cancelling an approved entry reverses its accrual; a paid one is not
     cancelled; a pending one with no entry alone is deleted.

A line of a month's run (PAYROLL-2, services/payroll_run) is the run's: its
accrual is the run's, and it is approved, cancelled and edited with the run.

  7. a month's salary is born in its run (HR-UX ط5; the owner, 2 Nov 2026:
     «اعتمد»): no entry is made, nor cloned, beside it -- the entries made one
     by one before the runs (all paid on production) keep laws 1-6.
"""
from __future__ import annotations

from models import JournalEntry, JournalEntryLine, db

AMOUNT_FIELDS = ('employee_id', 'month', 'year', 'basic_salary', 'allowances', 'deductions')
ACCRUAL = 'payroll_accrual'
REVERSAL = 'payroll_accrual_reversal'


class PayrollRefused(ValueError):
    def __init__(self, message: str, code: str | None = None):
        super().__init__(message)
        self.message = message
        self.code = code


def refuse_entry_outside_a_run() -> None:
    """Law 7."""
    raise PayrollRefused('راتب الشهر يُكتب من مسيره: يُنشأ مسير الشهر ويُضاف إليه الموظف',
                         'payroll_is_the_run')


def refuse_bad_period(month, year) -> None:
    """A month 1-12 of a four-digit year: «202» was saved for 2025 (the 31 Oct copy)."""
    try:
        m, y = int(month), int(year)
    except (TypeError, ValueError):
        raise PayrollRefused('الشهر والسنة رقمان') from None
    if not (1 <= m <= 12) or not (2000 <= y <= 2100):
        raise PayrollRefused('الشهر من 1 إلى 12، والسنة أربعة أرقام مثل 2026')


def net_of(basic, allowances, deductions) -> float:
    return round(float(basic or 0.0) + float(allowances or 0.0) - float(deductions or 0.0), 2)


RUN_LINE = 'سطر من مسير الشهر: يُعتمد ويُلغى ويُعدَّل مع المسير كله، من شاشة المسير.'


def refuse_run_line(entry) -> None:
    if entry.payroll_run_id is not None:
        raise PayrollRefused(RUN_LINE)


def accrual_of(entry):
    """Its posted accrual, standing (not reversed) -- or None. A run's line has its run's."""
    if entry.payroll_run_id is not None:
        from services.payroll_run import accrual_of as run_accrual_of
        return run_accrual_of(entry.run)
    accrual = (JournalEntry.query
               .filter_by(reference_type=ACCRUAL, reference_id=int(entry.id), is_deleted=False)
               .order_by(JournalEntry.id.desc()).first())
    if accrual is None:
        return None
    reversed_ = JournalEntry.query.filter_by(reference_type=REVERSAL, reference_id=int(entry.id),
                                             is_deleted=False).first()
    return None if reversed_ is not None else accrual


def refuse_amount_edit(entry, data: dict) -> None:
    """Law 1: an amount, the employee or the month changed on an entry not pending."""
    if entry.payroll_run_id is not None and any(data.get(field) is not None for field in AMOUNT_FIELDS):
        raise PayrollRefused(RUN_LINE)
    if (entry.status or '').strip().lower() == 'pending':
        return
    for field in AMOUNT_FIELDS:
        if field in data and data[field] is not None:
            current = getattr(entry, field)
            asked = float(data[field]) if isinstance(current, float) else int(data[field])
            if asked != current:
                raise PayrollRefused('لا تُعدَّل مبالغ سجل راتب بعد اعتماده: قيد استحقاقه مرحّل بها. '
                                     'ألغِ السجل (يُعكس قيده) وأنشئ سجلًا صحيحًا.')


def approve(entry, *, by: str) -> None:
    """Law 4: approved with its accrual, or left pending. Caller commits."""
    refuse_run_line(entry)
    from routes.employees import _post_payroll_accrual_internal
    savepoint = db.session.begin_nested()
    entry.status = 'approved'
    try:
        ok, err, _ = _post_payroll_accrual_internal(entry, created_by=by)
    except Exception as exc:          # noqa: BLE001 -- the entry stays pending, the reason said
        ok, err = False, str(exc)
    if ok:
        savepoint.commit()
        return
    savepoint.rollback()
    entry.status = 'pending'
    raise PayrollRefused(f'لم يُعتمد السجل لأن قيد استحقاقه لم يُكتب: {err}')


def ensure_accrual(entry, *, by: str) -> None:
    """Law 5: an approved entry paid has its accrual first -- a legacy one may have none."""
    status = (entry.status or '').strip().lower()
    if status not in ('approved', 'paid'):
        raise PayrollRefused('اعتمد سجل الراتب أولًا: يُكتب قيد استحقاقه، ثم يُصرف.')
    if accrual_of(entry) is None and status == 'approved':
        approve(entry, by=by)              # a run's line is refused here: its run has no accrual


def cancel(entry, *, by: str, now) -> None:
    """Law 6: a paid entry is not cancelled; an approved one's accrual is reversed. Caller commits."""
    refuse_run_line(entry)
    status = (entry.status or '').strip().lower()
    if status == 'paid' or entry.voucher_id:
        raise PayrollRefused('لا يُلغى راتب صُرف: سند صرفه قائم. يُلغى السند أولًا إن كان خطأ.')
    accrual = accrual_of(entry)
    if accrual is not None:
        reverse_entry(accrual, reference_type=REVERSAL, reference_id=int(entry.id),
                      description=f'عكس استحقاق راتب {entry.month}/{entry.year} (إلغاء السجل #{entry.id})',
                      by=by, now=now)
    entry.status = 'cancelled'


def refuse_delete(entry) -> None:
    """Law 6: only a pending entry with no entry of its own is deleted."""
    refuse_run_line(entry)
    if (entry.status or '').strip().lower() != 'pending' or entry.voucher_id or accrual_of(entry) is not None:
        raise PayrollRefused('لا يُحذف إلا سجل معلّق بلا قيد ولا سند؛ المعتمد يُلغى فيُعكس قيده.')


def reverse_entry(accrual, *, reference_type: str, reference_id: int, description: str, by: str,
                  now) -> JournalEntry:
    """An accrual's lines, debit for credit, posted -- an entry's or a run's."""
    from dual_system_helpers import create_dual_journal_entry, verify_dual_balance
    from accounting.balances import _recalculate_account_balances_for_accounts
    reversal = JournalEntry(date=now, description=description, entry_type='استحقاق رواتب',
                            reference_type=reference_type, reference_id=reference_id,
                            reference_number=accrual.reference_number, created_by=by,
                            is_posted=True, posted_at=now, posted_by=by)
    db.session.add(reversal)
    db.session.flush()
    lines = JournalEntryLine.query.filter_by(journal_entry_id=accrual.id, is_deleted=False).all()
    for line in lines:
        create_dual_journal_entry(journal_entry_id=reversal.id, account_id=line.account_id,
                                  cash_debit=float(line.cash_credit or 0.0),
                                  cash_credit=float(line.cash_debit or 0.0), description=description)
    if not verify_dual_balance(reversal.id).get('balanced', True):
        raise PayrollRefused('لم يتوازن قيد عكس الاستحقاق')
    _recalculate_account_balances_for_accounts({l.account_id for l in lines if l.account_id})
    return reversal
