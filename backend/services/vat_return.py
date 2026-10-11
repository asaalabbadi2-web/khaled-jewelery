"""A VAT return: a period's output and input VAT closed into what is owed to the authority (ADR-043, rule 5).

One posted entry at the period's last day: output VAT debited by what the
period credited it (2300, and 2210 where April's returns wrote theirs), input
VAT credited by what the period debited it (1400, 1410), the net on 2301
«صافي ضريبة القيمة المضافة المستحقة للهيئة» -- credit when owed, debit when due
back. Paying it is a payment voucher on 2301 from the bank (a refund, a
receipt): it extinguishes a liability, no expense -- the VAT was never revenue.

Refused: a period not over, a period overlapping one filed. A nil return is
recorded with no entry -- its period is filed all the same. A filing's own
entry never counts in a later period.
"""
from __future__ import annotations

import json
from collections import defaultdict
from datetime import date, datetime, time, timedelta

from sqlalchemy import func, or_

from accounting.balances import counted_line_filters
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
from models import Account, AccountingMapping, AuditLog, JournalEntry, JournalEntryLine, VatReturn, db
from services.sales_vat import sales_vat_account_ids

FILING = 'vat_return'
SETTLEMENT_ROLE = 'vat_settlement'
SETTLEMENT = ('2301', 'صافي ضريبة القيمة المضافة المستحقة للهيئة', '230')
CENT = 0.005


class VatReturnRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def settlement_account_id() -> int:
    """2301, mapped -- or made once under 230 with its weight twin, and mapped."""
    from employee_account_helpers import ensure_memo_for_account
    mapped = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, SETTLEMENT_ROLE)
    if mapped:
        return mapped
    number, name, parent_number = SETTLEMENT
    account = Account.query.filter_by(account_number=number).first()
    if account is None:
        parent = Account.query.filter_by(account_number=parent_number).first()
        if parent is None:
            raise VatReturnRefused('NO_VAT_PARENT', f'الحساب {parent_number} غير موجود لصافي الضريبة المستحقة')
        account = Account(account_number=number, name=name, type='Liability', transaction_type='cash',
                          parent_id=parent.id)
        db.session.add(account)
        db.session.flush()
        if parent.memo_account_id:
            ensure_memo_for_account(account)
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=SETTLEMENT_ROLE,
                                     account_id=account.id, is_active=True))
    db.session.flush()
    return account.id


def _input_vat_account_ids() -> set[int]:
    return {a for a in (get_account_id_for_mapping('شراء', 'vat_receivable'),
                        get_account_id_for_mapping('شراء من عميل', 'vat_receivable'),
                        get_account_id_for_mapping('بيع', 'commission_vat')) if a}


def _moved(account_ids, start: date, end: date) -> dict[int, float]:
    """{account id: cash debit - credit} of the counted lines dated in [start, end], filings left out."""
    rows = (db.session.query(JournalEntryLine.account_id,
                             func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(account_ids or {-1}),
                    JournalEntry.date >= datetime.combine(start, time.min),
                    JournalEntry.date < datetime.combine(end + timedelta(days=1), time.min),
                    or_(JournalEntry.reference_type.is_(None), JournalEntry.reference_type != FILING))
            .group_by(JournalEntryLine.account_id).all())
    return {i: float(v or 0) for i, v in rows}


def file_vat_return(*, start: date, end: date, by: str, now, dry_run: bool = False) -> dict:
    if start > end:
        raise VatReturnRefused('INVALID_PERIOD', 'بداية الفترة بعد نهايتها')
    if end >= now.date():
        raise VatReturnRefused('PERIOD_NOT_OVER', 'لا يُقدَّم إقرار لفترة لم تنتهِ')
    overlap = VatReturn.query.filter(VatReturn.period_start <= end, VatReturn.period_end >= start).first()
    if overlap is not None:
        raise VatReturnRefused('PERIOD_OVERLAPS', f'الفترة تتداخل مع إقرار {overlap.period_start} – {overlap.period_end}')

    number = dict(Account.query.with_entities(Account.id, Account.account_number).all())
    output = {i: -v for i, v in _moved(sales_vat_account_ids(), start, end).items()}        # credited
    input_ = _moved(_input_vat_account_ids(), start, end)                                    # debited
    lines = defaultdict(float)
    for i, v in output.items():
        lines[i] += v                     # debit what the period credited
    for i, v in input_.items():
        lines[i] -= v                     # credit what the period debited
    output_vat, input_vat = round(sum(output.values()), 2), round(sum(input_.values()), 2)
    net = round(output_vat - input_vat, 2)
    out = {'start': start.isoformat(), 'end': end.isoformat(), 'output_vat': output_vat, 'input_vat': input_vat,
           'net': net, 'lines': {number[i]: round(v, 2) for i, v in lines.items() if abs(v) > CENT},
           'entry_number': None}
    if dry_run:
        return out
    if abs(output_vat) < CENT and abs(input_vat) < CENT:
        # A nil return is a return: the period is filed, with no entry to write.
        db.session.add(VatReturn(period_start=start, period_end=end, output_vat=0.0, input_vat=0.0, net=0.0,
                                 filed_by=by, filed_at=now))
        db.session.flush()
        return out

    from services.repair.entries import write_entry
    owed = settlement_account_id()
    specs = [{'account_id': i, 'cash_debit': round(v, 2)} if v > 0 else {'account_id': i, 'cash_credit': round(-v, 2)}
             for i, v in lines.items() if abs(v) > CENT]
    if abs(net) > CENT:
        specs.append({'account_id': owed, 'cash_credit': net} if net > 0 else {'account_id': owed, 'cash_debit': -net})
    description = f'إقرار ضريبة القيمة المضافة {start:%Y-%m-%d} – {end:%Y-%m-%d} (ADR-043)'
    for spec in specs:
        spec['description'] = description
    entry = write_entry(date=datetime.combine(end, time(23, 59, 59)), description=description, reference_type=FILING,
                        reference_id=None, reference_number=f'{start:%Y-%m-%d}..{end:%Y-%m-%d}', lines=specs,
                        by=by, now=now, prefix='VAT', safe_rows=False)
    record = VatReturn(period_start=start, period_end=end, output_vat=output_vat, input_vat=input_vat, net=net,
                       journal_entry_id=entry.id, filed_by=by, filed_at=now)
    db.session.add(record)
    db.session.add(AuditLog(user_name=by, action=FILING, entity_type='journal_entry', entity_id=entry.id,
                            entity_number=entry.entry_number, success=True,
                            details=json.dumps(out, ensure_ascii=False, default=str)))
    db.session.flush()
    out['entry_number'] = entry.entry_number
    return out


def list_vat_returns() -> list[dict]:
    return [r.to_dict() for r in VatReturn.query.order_by(VatReturn.period_start).all()]
