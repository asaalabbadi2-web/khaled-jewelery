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
