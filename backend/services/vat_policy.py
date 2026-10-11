"""VAT as a dated policy -- two switches, in force from a day (ADR-043, phase 4).

The owner (11 Oct 2026): «مسجّلة في المدخلات والمخرجات لا، وهذا وضع مؤقت وليس
دائم». So not one «registered»: input VAT recovered, and sales charged VAT --
each a choice that will change. They live in periods (vat_policy_period): an
invoice is treated by the period in force on its date, and a change is a new
period from today on -- the past stays what it was (a sale of March, taxed
then, re-saved today is still taxed).

Without any period (a database before the migration seeds them) the company's
old switch, settings.sales_vat_enabled, is read, inputs recovered.
"""
from __future__ import annotations

from collections import namedtuple
from datetime import date

from models import Settings, VatPolicyPeriod, db

Policy = namedtuple('Policy', 'input_vat_recoverable sales_vat_charged')


class PeriodRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def policy_on(day: date) -> Policy:
    period = (VatPolicyPeriod.query.filter(VatPolicyPeriod.effective_from <= day)
              .order_by(VatPolicyPeriod.effective_from.desc()).first())
    if period is not None:
        return Policy(bool(period.input_vat_recoverable), bool(period.sales_vat_charged))
    settings = Settings.query.first()
    return Policy(True, bool(getattr(settings, 'sales_vat_enabled', True)) if settings else True)


def periods() -> list[dict]:
    return [p.to_dict() for p in VatPolicyPeriod.query.order_by(VatPolicyPeriod.effective_from).all()]


def add_period(*, effective_from: date, input_vat_recoverable: bool, sales_vat_charged: bool, by: str,
               today: date, note: str | None = None) -> VatPolicyPeriod:
    """A new period from *effective_from* -- today or later: the past stays what it was."""
    if effective_from < today:
        raise PeriodRefused('PERIOD_IN_THE_PAST', 'لا تبدأ فترة ضريبية في الماضي: ما رُحّل يبقى بوضعه')
    if not isinstance(input_vat_recoverable, bool) or not isinstance(sales_vat_charged, bool):
        raise PeriodRefused('INVALID_PERIOD', 'المفتاحان نعم أو لا')
    period = VatPolicyPeriod.query.filter_by(effective_from=effective_from).first()
    if period is None:
        period = VatPolicyPeriod(effective_from=effective_from)
        db.session.add(period)
    period.input_vat_recoverable, period.sales_vat_charged = input_vat_recoverable, sales_vat_charged
    period.created_by, period.note = by, note
    settings = Settings.query.first()
    if settings is not None and effective_from <= today:
        settings.sales_vat_enabled = sales_vat_charged       # the old switch follows today's period
    db.session.flush()
    return period


# ── where input VAT goes (rule 1) ─────────────────────────────────────────────
NON_RECOVERABLE_ROLE = 'vat_non_recoverable'
NON_RECOVERABLE_NAME = 'ضريبة القيمة المضافة غير القابلة للاسترداد'
NON_RECOVERABLE_PARENT = '540'          # المصاريف الإدارية والعمومية


def non_recoverable_account_id() -> int:
    """«ضريبة القيمة المضافة غير القابلة للاسترداد»: mapped, or made once under 540
    (paired with its weight twin as the chart pairs cash accounts) and mapped."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from employee_account_helpers import ensure_memo_for_account
    from models import Account, AccountingMapping
    mapped = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, NON_RECOVERABLE_ROLE)
    if mapped:
        return mapped
    account = Account.query.filter_by(name=NON_RECOVERABLE_NAME).first()
    if account is None:
        parent = Account.query.filter_by(account_number=NON_RECOVERABLE_PARENT).first()
        if parent is None:
            raise PeriodRefused('NO_EXPENSE_PARENT', f'الحساب {NON_RECOVERABLE_PARENT} غير موجود لضريبة غير مستردة')
        number = next(n for n in (f'{NON_RECOVERABLE_PARENT[:3]}{i}' for i in range(95, 100))
                      if not Account.query.filter_by(account_number=n).first())
        account = Account(account_number=number, name=NON_RECOVERABLE_NAME, type='Expense',
                          transaction_type='cash', parent_id=parent.id)
        db.session.add(account)
        db.session.flush()
        ensure_memo_for_account(account)
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=NON_RECOVERABLE_ROLE,
                                     account_id=account.id, is_active=True))
    db.session.flush()
    return account.id


def input_vat_account(day: date, *, operation_type: str, role: str = 'vat_receivable',
                      cost_account_id: int | None = None) -> int:
    """The account a VAT paid on *day* is debited to (rule 1): the input VAT
    account while inputs are recovered; else the cost it was paid on -- what
    enters the stock carries its VAT (IAS 2) -- or, on what does not,
    «ضريبة القيمة المضافة غير القابلة للاسترداد»."""
    from accounting.mappings import require_vat_account
    if policy_on(day).input_vat_recoverable:
        return require_vat_account(operation_type, role)
    return cost_account_id or non_recoverable_account_id()
