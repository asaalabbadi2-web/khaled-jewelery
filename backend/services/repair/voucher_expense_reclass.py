"""An expense posted on the wrong account, moved by an entry at its voucher's date (the owner, 5 Nov 2026).

The owner, «ينقل»: the workers' housing rent was paid by four vouchers --
PV-2026-00544, -00938, -01118, -01339; 1,750.00 on the 2 Nov copy -- posted
on the salaries account 5410 (found by the payroll report, REPORTS ت6-2ب). For
each named voucher, its amount on the *from* account moves to the *to*
account the owner made, by an entry dated the voucher's own entry (each
month's income statement stays right): debit *to*, credit *from*. Once per
voucher. The target must be an expense account. dry_run (the default)
writes nothing; an audit row names each moved.
"""
from __future__ import annotations

import datetime as dt
import json

from models import Account, AuditLog, JournalEntry, JournalEntryLine, Voucher, db

RECLASS = 'expense_reclassification'
ACTION = 'repair_voucher_expense_reclass'


class ReclassRefused(ValueError):
    pass


def reclassify(*, voucher_numbers, from_number: str, to_number: str, by: str, now: dt.datetime,
               dry_run: bool = True) -> dict:
    """*now*: the run's clock, passed in (ADR-015)."""
    from services.repair.entries import write_entry
    source = Account.query.filter_by(account_number=str(from_number)).first()
    target = Account.query.filter_by(account_number=str(to_number)).first()
    if source is None or target is None:
        raise ReclassRefused(f'لا حساب برقم {from_number if source is None else to_number}')
    if (target.type or '').lower() != 'expense':
        raise ReclassRefused(f'الحساب {to_number} ليس حساب مصروف')
    moved, skipped = [], []
    for number in voucher_numbers:
        voucher = Voucher.query.filter_by(voucher_number=number).first()
        entry = db.session.get(JournalEntry, voucher.journal_entry_id) if voucher and voucher.journal_entry_id else None
        if entry is None or not entry.is_posted or entry.is_deleted:
            skipped.append({'voucher': number, 'why': 'لا قيد مرحّل للسند'})
            continue
        if JournalEntry.query.filter_by(reference_type=RECLASS, reference_id=voucher.id, is_deleted=False).first():
            continue                                                    # moved already
        amount = round(float(db.session.query(db.func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
                             .filter(JournalEntryLine.journal_entry_id == entry.id,
                                     JournalEntryLine.account_id == source.id,
                                     db.func.coalesce(JournalEntryLine.is_deleted, False).is_(False)).scalar()
                             or 0.0), 2)
        if amount <= 0:
            skipped.append({'voucher': number, 'why': f'لا مبلغ مدين على {from_number}'})
            continue
        moved.append({'voucher': number, 'voucher_id': voucher.id, 'date': entry.date.isoformat(), 'amount': amount})
        if not dry_run:
            write_entry(date=entry.date, description=f'نقل {number} من {source.name} إلى {target.name}',
                        reference_type=RECLASS, reference_id=voucher.id, reference_number=number, by=by,
                        now=now, safe_rows=False,
                        lines=[{'account_id': target.id, 'cash_debit': amount, 'cash_credit': 0.0,
                                'description': f'نقل من {source.account_number} ({number})'},
                               {'account_id': source.id, 'cash_debit': 0.0, 'cash_credit': amount,
                                'description': f'نقل إلى {target.account_number} ({number})'}])
    plan = {'from': source.account_number, 'to': target.account_number, 'moved': moved, 'skipped': skipped,
            'total': round(sum(m['amount'] for m in moved), 2)}
    if dry_run or not moved:
        return plan
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='voucher', entity_id=moved[0]['voucher_id'],
                            success=True, details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
