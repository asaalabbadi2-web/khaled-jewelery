"""The commission VAT claimed before its tax invoice, put to wait (ADR-101; the owner, 25 Nov 2026).

Until ADR-101 a settlement claimed its commission's VAT on input VAT the day
its deposit was due. For a method now set to issue monthly tax invoices from
a month (`tax_invoice_from`), what its settlements and its deposits'
differences claimed from that month on is moved:
  - the share of the orders of that month on -- to the method's pending
    account, where its month's invoice, entered, claims it;
  - the share of the orders before it -- claimed already by their own
    invoices in the return that covered them (the owner: «نعم دخلت», Q3's
    return filed September's) -- to «ضريبة مدخلات مستردة من الإقرار», the
    account that return's input VAT was booked against (ADR-089): it was
    claimed twice.
One entry a month of the method, dated the month's last day (the run's day for
the month running), every figure read from the vouchers' own lines and their
settlement lines. Refused, writing nothing, when a figure cannot be read; a
second run finds the months done. Rehearsed on a copy, run on production
after the deploy and before the quarter's return and before its months are
locked.
"""
from __future__ import annotations

import calendar
import json
from collections import defaultdict
from datetime import date, datetime, time

from models import (Account, AuditLog, ClearingDeposit, ClearingDepositSettlement, Invoice, InvoicePayment,
                    JournalEntry, JournalEntryLine, PaymentMethod, SettlementLine, Voucher, db)
from services.commission_tax_invoice import month_start, pending_account
from services.repair.entries import write_entry

MOVED = 'commission_vat_wait'
RECOVERED_NAME = 'ضريبة مدخلات مستردة من الإقرار'
RECOVERED_PARENT_ROLE = 'vat_non_recoverable_parent'
CENT = 0.005


class NotAsFound(ValueError):
    pass


def recovered_account() -> Account:
    """«ضريبة مدخلات مستردة من الإقرار», made by the 2026 VAT repair (ADR-089) under its role's group."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    parent_id = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, RECOVERED_PARENT_ROLE)
    found = (Account.query.filter_by(parent_id=parent_id, name=RECOVERED_NAME).one_or_none()
             if parent_id else None)
    if found is None:
        raise NotAsFound(f'«{RECOVERED_NAME}» not found under {RECOVERED_PARENT_ROLE}')
    return found


def _claim_lines(voucher: Voucher, claims: set) -> dict:
    """{claim account id: debit - credit} of the voucher's posted entry."""
    from accounting.balances import counted_line_filters
    if not voucher.journal_entry_id:
        return {}
    out = defaultdict(float)
    for line in (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                 .filter(*counted_line_filters(), JournalEntry.id == voucher.journal_entry_id,
                         JournalEntryLine.account_id.in_(claims))):
        out[line.account_id] += float(line.cash_debit or 0.0) - float(line.cash_credit or 0.0)
    return {k: round(v, 2) for k, v in out.items() if abs(v) >= CENT}


def _early_share(lines: list, start: date, weight) -> float:
    """The share of *lines* (settlement lines) whose order is dated before *start*, by *weight*."""
    if not lines:
        return 0.0
    days = dict(db.session.query(InvoicePayment.id, Invoice.date).join(Invoice, Invoice.id == InvoicePayment.invoice_id)
                .filter(InvoicePayment.id.in_([ln.invoice_payment_id for ln in lines])).all())
    total = sum(weight(ln) for ln in lines)
    if total <= 0:
        return 0.0
    early = sum(weight(ln) for ln in lines
                if days.get(ln.invoice_payment_id) is not None and days[ln.invoice_payment_id].date() < start)
    return early / total


def plan(pm: PaymentMethod, now: datetime) -> list:
    """[{month, voucher numbers, {claim id: to move}, to pending, to recovered}] -- nothing written."""
    from services.vat_return import _input_vat_account_ids
    if pm.tax_invoice_from is None:
        raise NotAsFound(f'«{pm.name}»: no tax_invoice_from -- set the month it issues invoices from first')
    start = month_start(pm.tax_invoice_from)
    claims = _input_vat_account_ids()
    since = datetime.combine(start, time.min)
    settlements = (Voucher.query.filter(Voucher.reference_type == 'clearing_settlement',
                                        Voucher.reference_id == pm.default_safe_box_id,
                                        Voucher.status == 'approved', Voucher.date >= since).all()
                   if pm.default_safe_box_id else [])
    deposits = (db.session.query(Voucher, ClearingDeposit)
                .join(ClearingDeposit, ClearingDeposit.voucher_id == Voucher.id)
                .filter(ClearingDeposit.payment_method_id == pm.id, Voucher.status == 'approved',
                        Voucher.date >= since).all())
    months = defaultdict(lambda: {'vouchers': [], 'claims': defaultdict(float), 'pending': 0.0, 'recovered': 0.0})
    for voucher in settlements:
        on_claim = _claim_lines(voucher, claims)
        if not on_claim:
            continue
        lines = SettlementLine.query.filter_by(voucher_id=voucher.id).all()
        # By each line's VAT where the settlement split its VAT on them; else by what each settled.
        by_vat = sum(float(ln.commission_vat or 0.0) for ln in lines) > CENT
        early = _early_share(lines, start, (lambda ln: float(ln.commission_vat or 0.0)) if by_vat
                             else (lambda ln: float(ln.amount_settled or 0.0)))
        _add(months, voucher, on_claim, early)
    for voucher, deposit in deposits:
        on_claim = _claim_lines(voucher, claims)
        if not on_claim:
            continue
        ids = [link.voucher_id for link in ClearingDepositSettlement.query.filter_by(deposit_id=deposit.id).all()]
        lines = SettlementLine.query.filter(SettlementLine.voucher_id.in_(ids)).all() if ids else []
        early = _early_share(lines, start, lambda ln: float(ln.amount_settled or 0.0))
        _add(months, voucher, on_claim, early)
    out = []
    for month in sorted(months):
        m = months[month]
        out.append({'month': month.strftime('%Y-%m'), 'vouchers': sorted(m['vouchers']),
                    'claims': {k: round(v, 2) for k, v in m['claims'].items()},
                    'to_pending': round(m['pending'], 2), 'to_recovered': round(m['recovered'], 2),
                    'date': _dated(month, now).isoformat()})
    return out


def _add(months, voucher, on_claim, early):
    m = months[month_start(voucher.date.date())]
    m['vouchers'].append(voucher.voucher_number)
    vat = sum(on_claim.values())
    for account_id, amount in on_claim.items():
        m['claims'][account_id] += amount
    recovered = round(vat * early, 2)
    m['recovered'] += recovered
    m['pending'] += round(vat - recovered, 2)


def _dated(month: date, now: datetime) -> date:
    last = date(month.year, month.month, calendar.monthrange(month.year, month.month)[1])
    return min(last, now.date())


def move(pm: PaymentMethod, *, by: str, now: datetime) -> dict:
    """Write the moves; the caller commits (the CLI rolls back a dry run)."""
    from accounting.mappings import get_account_id_for_mapping
    months = plan(pm, now)
    claim = db.session.get(Account, get_account_id_for_mapping('بيع', 'commission_vat')
                           or get_account_id_for_mapping('بيع', 'vat_receivable') or 0)
    if claim is None:
        raise NotAsFound('commission_vat: no mapped account')
    pending = pending_account(pm, claim)
    recovered = None
    written, done = [], []
    for m in months:
        key = f'{pm.id}:{m["month"]}'
        found = JournalEntry.query.filter(JournalEntry.reference_type == MOVED, JournalEntry.reference_number == key,
                                          JournalEntry.is_deleted.isnot(True)).first()
        if found is not None:
            done.append({'month': m['month'], 'entry': found.entry_number})
            continue
        lines = [{'account_id': account_id, 'cash_credit': amount,
                  'description': 'ضريبة عمولة طولب بها قبل فاتورتها الضريبية'}
                 for account_id, amount in m['claims'].items() if amount >= CENT]
        lines += [{'account_id': account_id, 'cash_debit': -amount,
                   'description': 'ضريبة عمولة طولب بها قبل فاتورتها الضريبية'}
                  for account_id, amount in m['claims'].items() if amount <= -CENT]
        if m['to_pending'] >= CENT:
            lines.append({'account_id': pending.id, 'cash_debit': m['to_pending'],
                          'description': 'تنتظر فاتورة الشهر الضريبية'})
        elif m['to_pending'] <= -CENT:
            lines.append({'account_id': pending.id, 'cash_credit': -m['to_pending'],
                          'description': 'تنتظر فاتورة الشهر الضريبية'})
        if abs(m['to_recovered']) >= CENT:
            recovered = recovered or recovered_account()
            side = 'cash_debit' if m['to_recovered'] > 0 else 'cash_credit'
            lines.append({'account_id': recovered.id, side: abs(m['to_recovered']),
                          'description': 'طلبات ما قبل الفواتير: طولب بضريبتها في إقرارها'})
        if not lines:
            continue
        day = date.fromisoformat(m['date'])
        entry = write_entry(
            date=datetime.combine(day, time(23, 0)), reference_type=MOVED, reference_id=pm.id, reference_number=key,
            description=(f'ضريبة عمولات {pm.name} عن {m["month"]} تنتظر فاتورتها الضريبية (ADR-101): '
                         f'{", ".join(m["vouchers"][:6])}{"…" if len(m["vouchers"]) > 6 else ""}'),
            lines=lines, by=by, now=now, prefix='COR', entry_type='تصحيح')
        written.append({**m, 'entry': entry.entry_number})
    result = {'payment_method': pm.name, 'pending_account': pending.account_number, 'written': written,
              'done': done}
    if written:
        AuditLog.log_action(user_name=by, action='repair_commission_vat_wait', entity_type='PaymentMethod',
                            entity_id=pm.id, entity_number=pm.name,
                            details=json.dumps(result, ensure_ascii=False, default=str))
    return result
